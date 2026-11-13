package com.httparena;

import io.github.wycst.wast.common.reflect.GenericParameterizedType;
import io.github.wycst.wast.json.JSON;
import io.github.wycst.wastnet.http.HttpRequest;
import io.github.wycst.wastnet.http.HttpResponse;
import io.github.wycst.wastnet.http.annotation.ConverterConfig;
import io.github.wycst.wastnet.http.annotation.HttpMessageConverter;

import java.io.InputStream;
import java.lang.reflect.Type;

/** Serializes {@code @ResponseBody} return values with wast, the JSON library wastnet's MVC layer uses. */
public final class JsonMessageConverter implements HttpMessageConverter {

    @Override
    public void write(Object value, ConverterConfig config, HttpResponse response) throws Exception {
        response.contentType(config.getResponseContentType());
        if (config.isPretty()) {
            response.body(JSON.toPrettifyJsonString(value));
        } else {
            response.body(JSON.toJsonBytes(value));
        }
    }

    @Override
    public Object read(HttpRequest request, ConverterConfig config, Type type) throws Exception {
        GenericParameterizedType<?> parameterizedType = GenericParameterizedType.of(type);
        if (request.isStream()) {
            InputStream is = request.bodyStream();
            return JSON.read(is, parameterizedType);
        }
        byte[] data = request.getBodyData();
        if (data.length == 0) {
            return null;
        }
        return JSON.parse(data, parameterizedType);
    }
}
