package com.httparena;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

final class DelayWait {
    private DelayWait() {
    }

    static void await(int delayMillis) throws InterruptedException {
        if (delayMillis < 0) {
            throw new IllegalArgumentException("Delay must not be negative: " + delayMillis);
        }
        if (Thread.interrupted()) {
            throw new InterruptedException();
        }
        long remaining = TimeUnit.MILLISECONDS.toNanos(delayMillis);
        long deadline = System.nanoTime() + remaining;
        // Unlike virtual-thread sleep, park does not restore a permit that can
        // make the following socket wait return immediately. Recheck the deadline
        // because an unpark or a spurious wakeup must not shorten the requested delay.
        while (remaining > 0) {
            LockSupport.parkNanos(remaining);
            if (Thread.interrupted()) {
                throw new InterruptedException();
            }
            remaining = deadline - System.nanoTime();
        }
    }
}
