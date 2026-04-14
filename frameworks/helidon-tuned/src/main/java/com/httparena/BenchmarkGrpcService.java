package com.httparena;

import java.io.UncheckedIOException;

import io.helidon.webserver.grpc.GrpcService;

import benchmark.Benchmark;
import com.google.protobuf.Descriptors;
import io.grpc.stub.StreamObserver;

import static io.helidon.grpc.core.ResponseHelper.complete;

final class BenchmarkGrpcService implements GrpcService {
    @Override
    public String serviceName() {
        return "BenchmarkService";
    }

    @Override
    public Descriptors.FileDescriptor proto() {
        return Benchmark.getDescriptor();
    }

    @Override
    public void update(Routing router) {
        router.unary("GetSum", this::getSum)
                .serverStream("StreamSum", this::streamSum);
    }

    void getSum(Benchmark.SumRequest request, StreamObserver<Benchmark.SumReply> observer) {
        complete(observer, Benchmark.SumReply.newBuilder()
                .setResult(request.getA() + request.getB())
                .build());
    }

    void streamSum(Benchmark.StreamRequest request, StreamObserver<Benchmark.SumReply> observer) {
        try {
            int sum = request.getA() + request.getB();
            int count = Math.max(request.getCount(), 0);

            for (int i = 0; i < count; i++) {
                observer.onNext(Benchmark.SumReply.newBuilder()
                                       .setResult(sum + i)
                                       .build());
            }

            observer.onCompleted();
        } catch (UncheckedIOException e) {
            // this a connection close, we just ignore it
            return;
        }
    }
}
