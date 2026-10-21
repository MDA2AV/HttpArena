package httparena;

import io.micronaut.serde.annotation.Serdeable;

/** Nested rating object, kept nested in the response. */
@Serdeable
public record Rating(long score, long count) {
}
