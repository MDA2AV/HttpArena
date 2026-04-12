#!/bin/sh
set -e

NPROC=$(nproc)

# Generate h2o.conf
CERT_FILE=${TLS_CERT:-/certs/server.crt}
KEY_FILE=${TLS_KEY:-/certs/server.key}

cat > /tmp/h2o.conf << EOF
num-threads: ${NPROC}

listen:
  port: 8080
EOF

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
cat >> /tmp/h2o.conf << EOF

listen: &ssl_listen
  port: 8443
  ssl:
    certificate-file: ${CERT_FILE}
    key-file: ${KEY_FILE}

listen:
  <<: *ssl_listen
  type: quic
EOF
fi

cat >> /tmp/h2o.conf << EOF

hosts:
  default:
    paths:
      "/pipeline":
        mruby.handler: |
          Proc.new { [200, {"content-type" => "text/plain"}, ["ok"]] }

      "/baseline11":
        mruby.handler: |
          Proc.new do |env|
            sum = 0
            qs = env["QUERY_STRING"]
            if qs
              qs.split("&").each do |pair|
                _k, v = pair.split("=", 2)
                sum += v.to_i if v
              end
            end
            if env["REQUEST_METHOD"] == "POST"
              body = env["rack.input"] ? env["rack.input"].read : ""
              body = body.strip
              sum += body.to_i if body.length > 0
            end
            [200, {"content-type" => "text/plain"}, [sum.to_s]]
          end

      "/baseline2":
        mruby.handler: |
          Proc.new do |env|
            sum = 0
            qs = env["QUERY_STRING"]
            if qs
              qs.split("&").each do |pair|
                _k, v = pair.split("=", 2)
                sum += v.to_i if v
              end
            end
            [200, {"content-type" => "text/plain"}, [sum.to_s]]
          end

      "/upload":
        mruby.handler: |
          Proc.new do |env|
            input = env["rack.input"]
            body = input ? input.read : ""
            [200, {"content-type" => "text/plain"}, [body.bytesize.to_s]]
          end

      "/json":
        mruby.handler: |
          \$dataset = nil
          Proc.new do |env|
            unless \$dataset
              \$dataset = JSON.parse(File.open("/data/dataset.json", "r").read)
            end
            path = env["PATH_INFO"]
            count_str = path.split("/").last
            count = count_str.to_i
            count = 0 if count < 0
            count = \$dataset.length if count > \$dataset.length
            m = 1
            qs = env["QUERY_STRING"]
            if qs
              qs.split("&").each do |pair|
                k, v = pair.split("=", 2)
                m = v.to_i if k == "m" && v
              end
            end
            m = 1 if m == 0
            items = \$dataset[0, count].map do |d|
              item = {}
              d.each { |k, v| item[k] = v }
              item["total"] = d["price"] * d["quantity"] * m
              item
            end
            body = JSON.generate({"items" => items, "count" => count})
            [200, {"content-type" => "application/json"}, [body]]
          end

      "/static":
        file.dir: /data/static
        file.send-compressed: ON
EOF

exec h2o -c /tmp/h2o.conf
