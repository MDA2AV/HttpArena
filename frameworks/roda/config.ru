require_relative 'app'

use Rack::Deflater # enable gzip
run App
