vcl 4.1;

import httparena;

backend default none;

sub vcl_recv {
    return (synth(200));
}

sub vcl_synth {
    set resp.http.Content-Type = "text/plain";

    if (req.url == "/pipeline") {
        synthetic("ok");
    } else if (req.url ~ "^/baseline11(\?|$)") {
        synthetic(httparena.baseline_sum(req.url));
    } else {
        set resp.status = 404;
    }

    return (deliver);
}
