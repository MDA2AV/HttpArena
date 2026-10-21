package httparena;

import io.micronaut.core.annotation.Nullable;
import io.micronaut.http.HttpResponse;
import io.micronaut.http.HttpStatus;
import io.micronaut.http.MediaType;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.Header;
import io.micronaut.http.annotation.PathVariable;
import io.micronaut.http.server.types.files.SystemFile;

import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Serves /static/{name} from the data directory. A pre-compressed twin (name.br or name.gz) that
 * already sits next to the file is sent as is when the client accepts that encoding, so nothing is
 * compressed at request time. Every request goes to the file system, so a replaced file is seen at once.
 */
@Controller("/static")
public class StaticController {

    private static final Path DIR = Path.of(System.getenv().getOrDefault("STATIC_DIR", "/data/static")).toAbsolutePath().normalize();

    @Get("/{name}")
    public HttpResponse<?> file(@PathVariable String name, @Header("Accept-Encoding") @Nullable String acceptEncoding) {
        Path file = DIR.resolve(name).normalize();
        if (!file.startsWith(DIR) || !Files.isRegularFile(file)) {
            return HttpResponse.status(HttpStatus.NOT_FOUND);
        }
        MediaType type = MediaType.forFilename(name);
        Path send = file;
        String encoding = null;
        if (acceptEncoding != null) {
            Path br = DIR.resolve(name + ".br");
            Path gz = DIR.resolve(name + ".gz");
            if (acceptEncoding.contains("br") && Files.isRegularFile(br)) {
                send = br;
                encoding = "br";
            } else if (acceptEncoding.contains("gzip") && Files.isRegularFile(gz)) {
                send = gz;
                encoding = "gzip";
            }
        }
        var response = HttpResponse.ok(new SystemFile(send.toFile(), type));
        return encoding == null ? response : response.header("Content-Encoding", encoding);
    }
}
