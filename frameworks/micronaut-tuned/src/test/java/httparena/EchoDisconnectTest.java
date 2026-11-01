package httparena;

import io.micronaut.context.ApplicationContext;
import io.micronaut.http.netty.channel.ChannelPipelineCustomizer;
import io.micronaut.http.server.netty.NettyServerCustomizer;
import io.micronaut.runtime.server.EmbeddedServer;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.UnpooledByteBufAllocator;
import io.netty.channel.Channel;
import io.netty.channel.ChannelDuplexHandler;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelPromise;
import io.netty.handler.codec.http.HttpContent;
import org.junit.jupiter.api.Test;

import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class EchoDisconnectTest {
    @Test
    void socketDisconnectReleasesInputAndNativeResponses() throws Exception {
        var connections = new LinkedBlockingQueue<Connection>();
        try (ApplicationContext context = EchoControllerTest.serverContext(Map.of("micronaut.server.http-version", "1.1"))) {
            context.getBean(NettyServerCustomizer.Registry.class).register(new NettyServerCustomizer() {
                @Override
                public NettyServerCustomizer specializeForChannel(Channel channel, ChannelRole role) {
                    if (role != ChannelRole.CONNECTION) {
                        return this;
                    }
                    // No pooling/recycling: a captured buffer's refCnt stays zero after release.
                    channel.config().setAllocator(UnpooledByteBufAllocator.DEFAULT);
                    Connection connection = new Connection(channel);
                    connections.add(connection);
                    return new NettyServerCustomizer() {
                        @Override
                        public void onStreamPipelineBuilt() {
                            channel.pipeline().addBefore(ChannelPipelineCustomizer.HANDLER_MICRONAUT_INBOUND, "echo-ownership", new ChannelDuplexHandler() {
                                @Override
                                public void channelRead(ChannelHandlerContext ctx, Object message) throws Exception {
                                    if (message instanceof HttpContent content && content.content().isReadable()) {
                                        connection.buffers.add(content.content());
                                        connection.input.countDown();
                                    }
                                    super.channelRead(ctx, message);
                                }

                                @Override
                                public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) throws Exception {
                                    if (message instanceof HttpContent content && content.content().isReadable()) {
                                        connection.buffers.add(content.content());
                                        connection.output.countDown();
                                    }
                                    super.write(ctx, message, promise);
                                }
                            });
                        }
                    };
                }
            });
            EmbeddedServer server = context.getBean(EmbeddedServer.class).start();
            for (boolean fullBody : new boolean[]{false, true}) {
                try (Socket socket = new Socket()) {
                    socket.setReceiveBufferSize(1024);
                    socket.connect(new java.net.InetSocketAddress("localhost", server.getPort()));
                    Connection connection = connections.poll(5, TimeUnit.SECONDS);
                    assertNotNull(connection);
                    socket.setSoLinger(true, 0);
                    var output = socket.getOutputStream();
                    output.write("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                    output.write(new byte[fullBody ? 1048576 : 8192]);
                    output.flush();
                    assertTrue(connection.input.await(5, TimeUnit.SECONDS));
                    if (fullBody) {
                        assertTrue(connection.output.await(5, TimeUnit.SECONDS));
                    }
                    socket.close();
                    assertTrue(connection.channel.closeFuture().await(5, TimeUnit.SECONDS));
                    connection.channel.eventLoop().submit(() -> {}).get(5, TimeUnit.SECONDS);
                    assertFalse(connection.buffers.isEmpty());
                    for (ByteBuf buffer : connection.buffers) {
                        assertEquals(0, buffer.refCnt(), "unreleased native buffer after disconnect, full body: " + fullBody);
                    }
                }
            }
        }
    }

    private static final class Connection {
        final Channel channel;
        final ConcurrentLinkedQueue<ByteBuf> buffers = new ConcurrentLinkedQueue<>();
        final CountDownLatch input = new CountDownLatch(1);
        final CountDownLatch output = new CountDownLatch(1);

        Connection(Channel channel) {
            this.channel = channel;
        }
    }
}
