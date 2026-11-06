// Command fit is fit, with the httparena module compiled in: what `fit build
// -with` generates, written out so that the image builds it with the go
// command alone. It keeps fit's handlers and middleware (modules/standard),
// among them static and respond, and leaves out the providers and the roles
// beside the gateway (the tunnel, the LLM feature, the TURN server), which the
// config names none of, as `fit build -without` does.
package main

import (
	"os"

	"github.com/lesismal/fit/cli"
	_ "github.com/lesismal/fit/modules/standard"

	_ "httparena/fit/httparena"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], os.Stdout, os.Stderr))
}
