#pragma once

// Incremental RFC 6455 frame codec shared by ClassicServer and CoroServer.
//
// Reads normally carry whole frames, so the common path parses straight out of
// the transport's buffer with no intermediate queue: each frame is unmasked in
// place, and only a trailing partial frame is copied into `carry_`.
//
// Echoes are accumulated into one egress buffer per read, so a read carrying N
// pipelined frames produces one write rather than N. Small payloads (the echo
// profiles use ~128 bytes) are memcpy'd into that buffer, which is cheaper than
// the per-frame IOBuf bookkeeping a zero-copy view would cost. Large payloads
// cross over, and are emitted as a clone view of the read buffer instead: the
// answer to a frame reuses the same length encoding as the question, so the
// server header lands exactly on the four mask bytes preceding the payload.

#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <vector>

#include <folly/io/IOBuf.h>
#include <folly/io/IOBufQueue.h>

#include "ArenaCommon.h"

namespace httparena {

class WebSocketEcho {
public:
  enum class Opcode : uint8_t {
    Continuation = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xa,
  };

  // Payloads at or above this are echoed as a view of the read buffer; below
  // it, copying into the shared egress buffer costs less than a second IOBuf.
  static constexpr size_t kZeroCopyThreshold = 4096;

  void onIngress(std::unique_ptr<folly::IOBuf> data) {
    if (finished_ || !data) {
      return;
    }
    if (data->isChained()) {
      data->coalesce();
    }
    if (carry_.empty()) {
      const size_t consumed =
          parse(data->writableData(), data->length(), data.get());
      if (consumed < data->length()) {
        carry_.assign(data->data() + consumed, data->data() + data->length());
      }
      return;
    }
    append(carry_, data->data(), data->length());
    // No owning IOBuf for the carried bytes, so this path always copies. It
    // only runs when a previous read ended mid-frame.
    const size_t consumed = parse(carry_.data(), carry_.size(), nullptr);
    if (consumed == carry_.size()) {
      carry_.clear();
    } else if (consumed > 0) {
      carry_.erase(carry_.begin(),
                   carry_.begin() + static_cast<ptrdiff_t>(consumed));
    }
  }

  // Everything queued since the last call, or nullptr if there is nothing.
  std::unique_ptr<folly::IOBuf> takeEgress() {
    return egress_.empty() ? nullptr : egress_.move();
  }

  // At most `limit` bytes, for the coro HTTPSource, which is handed a per-read
  // size cap.
  std::unique_ptr<folly::IOBuf> takeEgress(size_t limit) {
    if (egress_.empty()) {
      return nullptr;
    }
    if (egress_.chainLength() <= limit) {
      return egress_.move();
    }
    return egress_.split(limit);
  }

  bool hasEgress() const { return !egress_.empty(); }

  // True once a close frame has been answered or the stream is unusable: the
  // caller should send EOM after flushing whatever is still queued.
  bool finished() const { return finished_; }

private:
  // Writes an unmasked server frame header for `payloadLength` into `out`,
  // which must have room for 10 bytes. Returns the header length.
  static size_t writeHeader(uint8_t *out, uint8_t opcode,
                            uint64_t payloadLength) {
    out[0] = static_cast<uint8_t>(0x80U | opcode);
    if (payloadLength <= 125) {
      out[1] = static_cast<uint8_t>(payloadLength);
      return 2;
    }
    if (payloadLength <= std::numeric_limits<uint16_t>::max()) {
      out[1] = 126;
      out[2] = static_cast<uint8_t>((payloadLength >> 8) & 0xff);
      out[3] = static_cast<uint8_t>(payloadLength & 0xff);
      return 4;
    }
    out[1] = 127;
    for (int shift = 56, index = 2; shift >= 0; shift -= 8, ++index) {
      out[index] = static_cast<uint8_t>((payloadLength >> shift) & 0xff);
    }
    return 10;
  }

  void queueFrame(uint8_t opcode, const uint8_t *payload, size_t length) {
    std::array<uint8_t, 10> header;
    const size_t headerLength = writeHeader(header.data(), opcode, length);
    egress_.append(header.data(), headerLength);
    if (length > 0) {
      egress_.append(payload, length);
    }
  }

  void closeWith(uint16_t status) {
    if (closeSent_ || finished_) {
      return;
    }
    const std::array<uint8_t, 2> payload = {
        static_cast<uint8_t>((status >> 8) & 0xff),
        static_cast<uint8_t>(status & 0xff)};
    queueFrame(static_cast<uint8_t>(Opcode::Close), payload.data(),
               payload.size());
    closeSent_ = true;
    finished_ = true;
  }

  void protocolError() { closeWith(1002); }
  void invalidPayload() { closeWith(1007); }
  void messageTooBig() { closeWith(1009); }

  // resize + memcpy rather than vector::insert from a raw pointer range:
  // same work, and GCC 13 cannot bound the iterator form, which trips a
  // false-positive -Wstringop-overflow.
  static void append(std::vector<uint8_t> &out, const uint8_t *data,
                     size_t length) {
    const size_t offset = out.size();
    out.resize(offset + length);
    if (length > 0) {
      std::memcpy(out.data() + offset, data, length);
    }
  }

  // Unmasks `length` bytes in place. The mask repeats every four bytes, so it
  // is applied as a rotating 32-bit word rather than byte-at-a-time modulo.
  static void unmask(uint8_t *payload, size_t length,
                     const uint8_t *mask) noexcept {
    uint32_t maskWord;
    std::memcpy(&maskWord, mask, sizeof(maskWord));
    size_t index = 0;
    for (; index + sizeof(uint32_t) <= length; index += sizeof(uint32_t)) {
      uint32_t chunk;
      std::memcpy(&chunk, payload + index, sizeof(chunk));
      chunk ^= maskWord;
      std::memcpy(payload + index, &chunk, sizeof(chunk));
    }
    for (; index < length; ++index) {
      payload[index] ^= mask[index & 3U];
    }
  }

  // Echoes a large frame without copying its payload. `frame` points at the
  // start of the received frame inside `owner`:
  //   [header(headerLength)][mask(4)][payload]
  // The answer is [header(headerLength)][payload] with the same length
  // encoding, so the server header lands on offset 4 and the view starts
  // there. The mask has already been consumed by unmask().
  void echoAsView(folly::IOBuf *owner, uint8_t *frame, uint8_t opcode,
                  size_t headerLength, size_t payloadLength) {
    writeHeader(frame + 4, opcode, payloadLength);
    auto view = owner->cloneOne();
    const size_t offset = static_cast<size_t>(frame - owner->writableData());
    view->trimStart(offset + 4);
    view->trimEnd(view->length() - (headerLength + payloadLength));
    egress_.append(std::move(view), /*pack=*/false);
  }

  void handleControlFrame(uint8_t opcode, uint8_t *payload, size_t length) {
    switch (static_cast<Opcode>(opcode)) {
    case Opcode::Close:
      if (length == 1) {
        protocolError();
        return;
      }
      if (length >= 2) {
        const auto status = static_cast<uint16_t>(
            (static_cast<uint16_t>(payload[0]) << 8) | payload[1]);
        if (!validWebSocketCloseCode(status)) {
          protocolError();
          return;
        }
        if (!validUtf8(payload + 2, length - 2)) {
          invalidPayload();
          return;
        }
      }
      if (!closeSent_) {
        queueFrame(static_cast<uint8_t>(Opcode::Close), payload, length);
        closeSent_ = true;
      }
      finished_ = true;
      return;
    case Opcode::Ping:
      queueFrame(static_cast<uint8_t>(Opcode::Pong), payload, length);
      return;
    case Opcode::Pong:
      return;
    default:
      protocolError();
      return;
    }
  }

  // Consumes as many whole frames as `length` holds, unmasking in place.
  // `owner` is the IOBuf backing `base`, or nullptr when parsing carried bytes
  // (in which case large frames are copied rather than viewed). Returns the
  // number of bytes consumed.
  size_t parse(uint8_t *base, size_t length, folly::IOBuf *owner) {
    size_t cursor = 0;
    while (!finished_) {
      const size_t available = length - cursor;
      if (available < 2) {
        break;
      }
      uint8_t *frame = base + cursor;
      const uint8_t first = frame[0];
      const uint8_t second = frame[1];
      const bool fin = (first & 0x80U) != 0;
      const uint8_t opcode = first & 0x0fU;
      const bool control = (opcode & 0x08U) != 0;
      const uint8_t encodedLength = second & 0x7fU;

      // Reserved bits must be clear, clients must mask, and control frames may
      // not use an extended length encoding even for a short payload.
      if ((first & 0x70U) != 0 || (second & 0x80U) == 0 ||
          (control && encodedLength > 125)) {
        protocolError();
        return length;
      }

      size_t headerLength = 2;
      uint64_t payloadLength = encodedLength;
      if (encodedLength == 126) {
        headerLength = 4;
        if (available < headerLength) {
          break;
        }
        payloadLength = (static_cast<uint64_t>(frame[2]) << 8) |
                        static_cast<uint64_t>(frame[3]);
        if (payloadLength < 126) { // not minimally encoded
          protocolError();
          return length;
        }
      } else if (encodedLength == 127) {
        headerLength = 10;
        if (available < headerLength) {
          break;
        }
        if ((frame[2] & 0x80U) != 0) { // high bit of a 64-bit length is 0
          protocolError();
          return length;
        }
        payloadLength = 0;
        for (size_t index = 0; index < 8; ++index) {
          payloadLength = (payloadLength << 8) | frame[2 + index];
        }
        if (payloadLength <= std::numeric_limits<uint16_t>::max()) {
          protocolError();
          return length;
        }
      }

      if (payloadLength > kMaxWebSocketMessage) {
        messageTooBig();
        return length;
      }

      constexpr size_t kMaskLength = 4;
      const size_t frameLength =
          headerLength + kMaskLength + static_cast<size_t>(payloadLength);
      if (available < frameLength) {
        break;
      }

      uint8_t *payload = frame + headerLength + kMaskLength;
      const auto size = static_cast<size_t>(payloadLength);
      unmask(payload, size, frame + headerLength);
      cursor += frameLength;

      if (control) {
        if (!fin) {
          protocolError();
          return length;
        }
        handleControlFrame(opcode, payload, size);
        continue;
      }
      if (closeSent_) {
        continue; // draining after our own close
      }

      if (opcode == static_cast<uint8_t>(Opcode::Continuation)) {
        if (fragmentOpcode_ == 0) {
          protocolError();
          return length;
        }
        if (size > kMaxWebSocketMessage - fragmentPayload_.size()) {
          messageTooBig();
          return length;
        }
        append(fragmentPayload_, payload, size);
        if (fin) {
          finishFragmentedMessage();
        }
        continue;
      }

      if (opcode != static_cast<uint8_t>(Opcode::Text) &&
          opcode != static_cast<uint8_t>(Opcode::Binary)) {
        protocolError();
        return length;
      }
      if (fragmentOpcode_ != 0) { // interleaved new message
        protocolError();
        return length;
      }
      if (!fin) {
        fragmentOpcode_ = opcode;
        fragmentPayload_.assign(payload, payload + size);
        continue;
      }
      if (opcode == static_cast<uint8_t>(Opcode::Text) &&
          !validUtf8(payload, size)) {
        invalidPayload();
        return length;
      }

      if (owner != nullptr && size >= kZeroCopyThreshold) {
        echoAsView(owner, frame, opcode, headerLength, size);
      } else {
        queueFrame(opcode, payload, size);
      }
    }
    return cursor;
  }

  void finishFragmentedMessage() {
    if (fragmentOpcode_ == static_cast<uint8_t>(Opcode::Text) &&
        !validUtf8(fragmentPayload_)) {
      invalidPayload();
      return;
    }
    queueFrame(fragmentOpcode_, fragmentPayload_.data(),
               fragmentPayload_.size());
    fragmentOpcode_ = 0;
    fragmentPayload_.clear();
    fragmentPayload_.shrink_to_fit();
  }

  folly::IOBufQueue egress_{folly::IOBufQueue::cacheChainLength()};
  std::vector<uint8_t> carry_;
  std::vector<uint8_t> fragmentPayload_;
  uint8_t fragmentOpcode_{0};
  bool closeSent_{false};
  bool finished_{false};
};

} // namespace httparena
