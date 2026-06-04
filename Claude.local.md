This is HTTP Arena, a project to benchmark web server frameworks in different scenarios (such as static file handling or API serving).


Your job in this repository will be to add high quality framework benchmark implementations. Respect the following rules:


* Keep the implementations as clean and simple as possible
* Write code like you would do for an app that will be deployed to production (no hacks to be faster, just best practices used in the framework)
* Use high-level APIs whenever possible (e.g. using parameter mapping to an `int` in baseline instead of reading it from the request context)
* Use the documented middleware (e.g. compression) whenever possible. Do not find excuses to implement this functionality yourself.
* Do not adjust any code outside of your current framework folder
* If a framework is not capable of doing something (such as having native compression middleware) do tell me about this and ask, instead of adding an own implementation


You will find the specifications for the endpoints to be implemented in `site/content/docs`. Keep in mind that not all frameworks implement all test types (such as gRCP or Websockets) - that is perfectly fine.


If you need a reference, have a look at how `frameworks/genhttp-kestrel` or `frameworks/genhttp` are doing things.

