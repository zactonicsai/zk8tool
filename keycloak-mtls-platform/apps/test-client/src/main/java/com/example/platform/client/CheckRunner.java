package com.example.platform.client;

import java.io.PrintStream;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

/**
 * Runs named checks, prints each outcome as it happens and keeps the results
 * for the summary and the optional JUnit report. A check never aborts the run:
 * failures are recorded and the next check starts.
 */
final class CheckRunner {

    enum Status {
        PASS, FAIL, SKIP
    }

    /** Outcome of one check. */
    record Result(String id, String title, Status status, String detail, Duration duration) {
    }

    /** A check body: returns a human-readable detail line, or throws. */
    @FunctionalInterface
    interface Body {
        String run() throws Exception;
    }

    /** Thrown by a check whose expectation is not met. */
    static final class CheckFailedException extends RuntimeException {

        private static final long serialVersionUID = 1L;

        CheckFailedException(String message) {
            super(message);
        }
    }

    /** Thrown by a check that cannot run, e.g. because an earlier one failed. */
    static final class CheckSkippedException extends RuntimeException {

        private static final long serialVersionUID = 1L;

        CheckSkippedException(String message) {
            super(message);
        }
    }

    private final PrintStream out;
    private final List<Result> results = new ArrayList<>();

    CheckRunner(PrintStream out) {
        this.out = out;
    }

    void check(String id, String title, Body body) {
        long start = System.nanoTime();
        Status status;
        String detail;
        try {
            detail = body.run();
            status = Status.PASS;
        } catch (CheckSkippedException e) {
            status = Status.SKIP;
            detail = e.getMessage();
        } catch (CheckFailedException e) {
            status = Status.FAIL;
            detail = e.getMessage();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            status = Status.FAIL;
            detail = "interrupted";
        } catch (Exception e) {
            status = Status.FAIL;
            detail = describe(e);
        }
        record(new Result(id, title, status, detail, Duration.ofNanos(System.nanoTime() - start)));
    }

    void skip(String id, String title, String reason) {
        record(new Result(id, title, Status.SKIP, reason, Duration.ZERO));
    }

    List<Result> results() {
        return List.copyOf(results);
    }

    long count(Status status) {
        return results.stream().filter(result -> result.status() == status).count();
    }

    static void require(boolean condition, String message) {
        if (!condition) {
            throw new CheckFailedException(message);
        }
    }

    static <T> T requirePresent(T value, String skipReason) {
        if (value == null) {
            throw new CheckSkippedException(skipReason);
        }
        return value;
    }

    /**
     * Flattens an exception and its causes into one line. TLS failures hide
     * the useful part ("unable to find valid certification path", "bad
     * certificate") several causes deep.
     */
    static String describe(Throwable throwable) {
        StringBuilder text = new StringBuilder();
        Throwable current = throwable;
        int depth = 0;
        while (current != null && depth < 6) {
            if (depth > 0) {
                text.append(" <- ");
            }
            text.append(current.getClass().getSimpleName());
            if (current.getMessage() != null) {
                text.append(": ").append(current.getMessage());
            }
            current = current.getCause() == current ? null : current.getCause();
            depth++;
        }
        return text.toString();
    }

    private void record(Result result) {
        results.add(result);
        out.printf("[%s] %-7s %s (%d ms)%n", result.status(), result.id(), result.title(),
                result.duration().toMillis());
        if (result.detail() != null && !result.detail().isBlank()) {
            out.printf("       %s%n", result.detail());
        }
    }
}
