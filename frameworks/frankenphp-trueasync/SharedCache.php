<?php

/**
 * The crud cache-aside, in shared memory, with no sidecar.
 *
 * The server is one process with N worker threads, and true-async gives each
 * worker an isolated PHP context - so a plain array is per worker, and the
 * profile's two-request MISS-then-HIT check lands on two different workers and
 * sees MISS twice. This is the shape Swoole solves with Swoole\Table, solved the
 * same way: one fixed slot table that every worker maps.
 *
 * The table is a file on /dev/shm, which is tmpfs - so it is RAM, and reads and
 * writes are page-cache hits. It is deliberately not SysV shm: shmop is subject
 * to kernel limits that differ between machines, and it worked on a 32-core
 * developer box while reporting nothing but misses on a 4-core CI runner. A
 * tmpfs file has no such limits and behaves the same everywhere.
 *
 * Layout, repeated SLOTS times:
 *
 *     [ len:uint32 ][ crc:uint32 ][ expires_ms:double ][ body:BODY_MAX ]
 *
 * A key hashes straight to its slot, so a new key overwrites whatever was
 * there: the table is self-evicting and never grows, which matters when the
 * profile reads ids at random out of 50,000.
 *
 * There is no lock. A slot write is not atomic, so a reader can catch a torn
 * row - the crc is there to notice that and report a miss, which costs one
 * Postgres read and nothing else. Locking every worker around a 200 ms cache
 * would cost far more than the misses it saves.
 */
final class SharedCache
{
    private const SLOTS    = 8192;
    private const BODY_MAX = 1024;
    private const HEADER   = 16;                        // 4 + 4 + 8
    private const SLOT     = self::HEADER + self::BODY_MAX;

    private static $fh = null;
    private static bool $tried = false;

    private static function handle()
    {
        if (self::$fh !== null || self::$tried) {
            return self::$fh;
        }
        self::$tried = true;
        $dir  = is_dir('/dev/shm') && is_writable('/dev/shm') ? '/dev/shm' : sys_get_temp_dir();
        $path = $dir . '/httparena-crud-cache';
        $fh   = @fopen($path, 'c+b');
        if ($fh === false) {
            return null;
        }
        $size = self::SLOTS * self::SLOT;
        // Size it once. Racing workers all truncate to the same length, which is
        // harmless; ftruncate does not zero data that is already there.
        $stat = fstat($fh);
        if (($stat['size'] ?? 0) < $size) {
            @ftruncate($fh, $size);
        }
        // No stream buffering: a buffered reader would serve another worker's
        // write back stale.
        stream_set_read_buffer($fh, 0);
        stream_set_write_buffer($fh, 0);
        self::$fh = $fh;
        return $fh;
    }

    private static function offset(string $key): int
    {
        return (crc32($key) % self::SLOTS) * self::SLOT;
    }

    public static function get(string $key): ?string
    {
        $fh = self::handle();
        if ($fh === null) {
            return null;
        }
        if (@fseek($fh, self::offset($key)) !== 0) {
            return null;
        }
        $raw = @fread($fh, self::SLOT);
        if ($raw === false || strlen($raw) < self::HEADER) {
            return null;
        }
        $head = unpack('Vlen/Vcrc/dexpires', substr($raw, 0, self::HEADER));
        $len  = $head['len'];
        if ($len <= 0 || $len > self::BODY_MAX) {
            return null;
        }
        if ($head['expires'] <= microtime(true) * 1000) {
            return null;
        }
        $body = substr($raw, self::HEADER, $len);
        // Catches a row caught mid-write, and a slot holding a different key.
        if (crc32($body) !== $head['crc']) {
            return null;
        }
        return $body;
    }

    public static function setPx(string $key, string $value, int $ms): void
    {
        $fh = self::handle();
        if ($fh === null || strlen($value) > self::BODY_MAX) {
            return;
        }
        $row = pack('VVd', strlen($value), crc32($value), microtime(true) * 1000 + $ms)
             . $value;
        if (@fseek($fh, self::offset($key)) === 0) {
            @fwrite($fh, str_pad($row, self::SLOT, "\0"));
            @fflush($fh);
        }
    }

    public static function del(string $key): void
    {
        $fh = self::handle();
        if ($fh === null) {
            return;
        }
        // Zeroing the header is enough: len 0 reads as a miss.
        if (@fseek($fh, self::offset($key)) === 0) {
            @fwrite($fh, str_repeat("\0", self::HEADER));
            @fflush($fh);
        }
    }
}
