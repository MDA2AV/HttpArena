/*
 * ioma.h - umbrella header for the ioma HTTP/1.1 server framework. Include this and you have the
 * whole framework surface: requests, responses, routing, middleware, and ioma_run.
 *
 * For the raw byte-level runtime instead of HTTP (await_recv / await_send on the proactor),
 * include <proactor.h> as well.
 */
#pragma once

#include "http.h"
