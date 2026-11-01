package httparena;

import io.vertx.core.Vertx;
import io.vertx.pgclient.PgBuilder;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.PoolOptions;
import jakarta.annotation.PreDestroy;
import jakarta.inject.Singleton;

/** The asynchronous PostgreSQL pool shared by the database profiles; absent without DATABASE_URL. */
@Singleton
public class Database {

    private final Vertx vertx;
    private final Pool pool;

    Database() {
        String url = System.getenv("DATABASE_URL");
        if (url == null || url.isEmpty()) {
            vertx = null;
            pool = null;
            return;
        }
        // The harness caps the number of connections it allows; the pool is sized from that cap
        int maxConn = 256;
        String cap = System.getenv("DATABASE_MAX_CONN");
        if (cap != null && !cap.isEmpty()) {
            maxConn = Math.max(1, Integer.parseInt(cap));
        }
        vertx = Vertx.vertx();
        pool = PgBuilder.pool()
                .connectingTo(PgConnectOptions.fromUri(url).setCachePreparedStatements(true))
                .with(new PoolOptions().setMaxSize(maxConn))
                .using(vertx)
                .build();
    }

    /** The pool, or null when no database is configured. */
    Pool pool() {
        return pool;
    }

    @PreDestroy
    void close() {
        if (vertx != null) {
            vertx.close();
        }
    }
}
