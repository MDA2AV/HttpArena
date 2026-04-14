package com.httparena;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.List;

import benchmark.Benchmark;
import io.grpc.stub.StreamObserver;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class BenchmarkGrpcServiceTest {
    @Test
    void streamSumEmitsExactSequence() throws Exception {
        RecordingObserver observer = new RecordingObserver();
        BenchmarkGrpcService service = new BenchmarkGrpcService();

        service.streamSum(Benchmark.StreamRequest.newBuilder()
                                  .setA(13)
                                  .setB(42)
                                  .setCount(3)
                                  .build(),
                          observer);

        assertEquals(List.of(55, 56, 57), observer.results);
        assertEquals(1, observer.completedCount);
        assertNull(observer.error);
    }

    @Test
    void streamSumAllowsEmptyStreamWhenCountIsZero() throws Exception {
        RecordingObserver observer = new RecordingObserver();
        BenchmarkGrpcService service = new BenchmarkGrpcService();

        service.streamSum(Benchmark.StreamRequest.newBuilder()
                                  .setA(13)
                                  .setB(42)
                                  .setCount(0)
                                  .build(),
                          observer);

        assertEquals(List.of(), observer.results);
        assertEquals(1, observer.completedCount);
        assertNull(observer.error);
    }

    @Test
    void streamSumStopsQuietlyWhenClientDisconnects() throws Exception {
        ThrowingObserver observer = new ThrowingObserver();
        BenchmarkGrpcService service = new BenchmarkGrpcService();

        service.streamSum(Benchmark.StreamRequest.newBuilder()
                                  .setA(13)
                                  .setB(42)
                                  .setCount(3)
                                  .build(),
                          observer);

        assertEquals(List.of(55), observer.results);
        assertEquals(0, observer.completedCount);
        assertNull(observer.error);
    }

    private static final class RecordingObserver implements StreamObserver<Benchmark.SumReply> {
        private final List<Integer> results = new ArrayList<>();
        private int completedCount;
        private Throwable error;

        @Override
        public void onNext(Benchmark.SumReply value) {
            results.add(value.getResult());
        }

        @Override
        public void onError(Throwable throwable) {
            error = throwable;
        }

        @Override
        public void onCompleted() {
            completedCount++;
        }
    }

    private static final class ThrowingObserver implements StreamObserver<Benchmark.SumReply> {
        private final List<Integer> results = new ArrayList<>();
        private int completedCount;
        private Throwable error;

        @Override
        public void onNext(Benchmark.SumReply value) {
            results.add(value.getResult());
            throw new UncheckedIOException(new IOException("stream closed"));
        }

        @Override
        public void onError(Throwable throwable) {
            error = throwable;
        }

        @Override
        public void onCompleted() {
            completedCount++;
        }
    }
}
