vcl 4.1;

import httparena;

backend default none;

sub vcl_recv {
    return (synth(200));
}

sub vcl_synth {
    set resp.http.Content-Type = "text/plain";

    if (req.url == "/pipeline") {
        set resp.body = "ok";
    } else if (req.url ~ "^/baseline11(\?|$)") {
        set resp.body = httparena.baseline_sum(req.url);
    } else {
        set resp.status = 404;
    }

    return (deliver);
}
