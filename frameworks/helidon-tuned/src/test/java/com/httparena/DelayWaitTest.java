package com.httparena;

import java.time.Duration;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class DelayWaitTest {
    @Test
    void waitsAtLeastRequestedDelayOnSameVirtualThread() throws Exception {
        onVirtualThread(() -> {
            Thread requestThread = Thread.currentThread();
            for (int millis : List.of(0, 1, 10, 37)) {
                long started = System.nanoTime();
                DelayWait.await(millis);
                long elapsed = System.nanoTime() - started;
                assertSame(requestThread, Thread.currentThread());
                assertTrue(requestThread.isVirtual());
                assertTrue(elapsed >= TimeUnit.MILLISECONDS.toNanos(millis),
                           millis + " ms returned after " + elapsed + " ns");
            }
            return null;
        });
    }

    @Test
    void rejectsNegativeDelay() {
        assertThrows(IllegalArgumentException.class, () -> DelayWait.await(-1));
    }

    @Test
    void alreadyInterruptedWaitClearsFlagIncludingZeroDelay() throws Exception {
        for (int millis : List.of(0, 10)) {
            onVirtualThread(() -> {
                Thread.currentThread().interrupt();
                assertThrows(InterruptedException.class, () -> DelayWait.await(millis));
                assertFalse(Thread.currentThread().isInterrupted());
                return null;
            });
        }
    }

    @Test
    void interruptionEndsOutstandingWaitOnOriginalVirtualThread() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        FutureTask<Void> task = new FutureTask<>(() -> {
            Thread requestThread = Thread.currentThread();
            entered.countDown();
            assertThrows(InterruptedException.class, () -> DelayWait.await(Integer.MAX_VALUE));
            assertSame(requestThread, Thread.currentThread());
            assertFalse(requestThread.isInterrupted());
            return null;
        });
        Thread thread = Thread.startVirtualThread(task);
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS));
            awaitSuspension(thread);
            thread.interrupt();
            task.get(5, TimeUnit.SECONDS);
        } finally {
            stop(thread);
        }
    }

    @Test
    void unparkCannotEndDelayEarly() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        FutureTask<Long> task = new FutureTask<>(() -> {
            // Also exercise a permit already available on entry to the wait.
            LockSupport.unpark(Thread.currentThread());
            long started = System.nanoTime();
            entered.countDown();
            DelayWait.await(500);
            return System.nanoTime() - started;
        });
        Thread thread = Thread.startVirtualThread(task);
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS));
            awaitSuspension(thread);
            LockSupport.unpark(thread);
            long elapsed = task.get(5, TimeUnit.SECONDS);
            assertTrue(elapsed >= TimeUnit.MILLISECONDS.toNanos(500), "Returned early after " + elapsed + " ns");
        } finally {
            stop(thread);
        }
    }

    private static <T> T onVirtualThread(Callable<T> callable) throws Exception {
        FutureTask<T> task = new FutureTask<>(callable);
        Thread thread = Thread.startVirtualThread(task);
        try {
            return task.get(5, TimeUnit.SECONDS);
        } finally {
            stop(thread);
        }
    }

    private static void awaitSuspension(Thread thread) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (System.nanoTime() < deadline && thread.isAlive()) {
            Thread.State state = thread.getState();
            if (state == Thread.State.WAITING || state == Thread.State.TIMED_WAITING) {
                return;
            }
            Thread.sleep(1);
        }
        assertEquals(Thread.State.TIMED_WAITING, thread.getState(), "Thread did not suspend before deadline");
    }

    private static void stop(Thread thread) throws InterruptedException {
        thread.interrupt();
        thread.join(Duration.ofSeconds(5));
        assertFalse(thread.isAlive(), "Virtual test thread did not stop");
    }
}
