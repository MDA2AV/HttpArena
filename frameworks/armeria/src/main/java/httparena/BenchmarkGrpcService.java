package httparena;

import benchmark.Benchmark.StreamRequest;
import benchmark.Benchmark.SumReply;
import benchmark.Benchmark.SumRequest;
import benchmark.BenchmarkServiceGrpc;
import io.grpc.stub.StreamObserver;

final class BenchmarkGrpcService extends BenchmarkServiceGrpc.BenchmarkServiceImplBase {

    @Override
    public void getSum(SumRequest req, StreamObserver<SumReply> observer) {
        observer.onNext(SumReply.newBuilder().setResult(req.getA() + req.getB()).build());
        observer.onCompleted();
    }

    @Override
    public void streamSum(StreamRequest req, StreamObserver<SumReply> observer) {
        final int sum = req.getA() + req.getB();
        for (int i = 0; i < req.getCount(); i++) {
            observer.onNext(SumReply.newBuilder().setResult(sum + i).build());
        }
        observer.onCompleted();
    }
}
