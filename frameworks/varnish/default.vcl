vcl 4.1;

import fileserver;
import httparena;

backend default none;

sub vcl_init {
    new static = fileserver.root("/data", "/etc/varnish/mime.types");
}

sub vcl_recv {
    if (req.url ~ "^/static/") {
        set req.backend_hint = static.backend();
    } else {
        return (synth(200));
    }
}

sub vcl_synth {
    set resp.http.Content-Type = "text/plain";

    if (req.url == "/pipeline") {
        synthetic("ok");
    } else if (req.url ~ "^/baseline(11|2)(\?|$)") {
        synthetic(httparena.baseline_sum());
    } else {
        set resp.status = 404;
    }

    return (deliver);
}
