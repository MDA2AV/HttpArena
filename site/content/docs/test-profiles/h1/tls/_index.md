---
title: TLS Hardening (opt-in)
seo_title: "TLS Hardening: Opt-in Validation"
description: "An opt-in validation section for the HTTP/1.1 TLS listener: certificate rotation, SNI, resumption, close_notify and a vulnerability scan. Nothing is measured; passing earns the gold TLS badge."
---

An opt-in set of TLS checks for the HTTP/1.1 TLS listener. Nothing here is measured or scored. An entry that turns it on with `"tls_check": true` in `meta.json` and passes it earns the gold TLS badge on the HTTP/1.1 board.

{{< cards >}}
  {{< card link="validation" title="Validation" subtitle="The listener on port 9000, the checks it has to pass, and what the badge means." icon="check-circle" >}}
{{< /cards >}}
