package httparena;

/** Nested rating object, kept nested in the response. */
public record Rating(long score, long count) {
}
