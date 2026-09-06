package com.httparena.spring.boot;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/delay")
public class DelayController {

    @GetMapping(path = "/{ms}", produces = MediaType.TEXT_PLAIN_VALUE)
    public String delay(@PathVariable int ms) throws InterruptedException {
        // spring.threads.virtual is enabled, so the request is on a virtual thread and this
        // parks it rather than a carrier thread.
        if (ms > 0) {
            Thread.sleep(ms);
        }
        return String.valueOf(ms);
    }

}
