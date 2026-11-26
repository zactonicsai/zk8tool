// kubegen reads a cluster definition (see schema/cluster.schema.yaml) and
// writes either a shell script that creates the cluster with the provider's
// CLI, or a Terraform configuration that does the same.
package main

import (
	"flag"
	"fmt"
	"os"
)

const (
	exitUsage        = 2
	exitInvalid      = 3
	exitMissingTools = 4
)

func main() {
	file := flag.String("f", "", "cluster definition YAML file (required)")
	format := flag.String("format", "shell", "what to generate: shell (a bash script) or terraform (a directory of .tf files)")
	out := flag.String("o", "", "output path\nshell:     script file, \"-\" for stdout (default create-<name>.sh)\nterraform: directory (default terraform-<name>)")
	skipTools := flag.Bool("skip-tool-check", false,
		"generate even if required CLIs are missing on this machine")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: kubegen -f cluster.yaml [-format shell|terraform] [-o path] [-skip-tool-check]")
		flag.PrintDefaults()
	}
	flag.Parse()
	if *file == "" || flag.NArg() > 0 || (*format != "shell" && *format != "terraform") {
		flag.Usage()
		os.Exit(exitUsage)
	}
	if *format == "terraform" && *out == "-" {
		fmt.Fprintln(os.Stderr, "error: -format terraform writes several files; give -o a directory")
		os.Exit(exitUsage)
	}

	cfg, err := loadConfig(*file)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(exitInvalid)
	}
	// kind without an explicit runtime: use Podman when that is what this
	// machine has, instead of generating Docker output that cannot work here.
	if cfg.Provider == "kind" && (cfg.Kind == nil || cfg.Kind.Runtime == "") {
		if cfg.Kind == nil {
			cfg.Kind = &KindConfig{}
		}
		runtime, reason := detectKindRuntime()
		cfg.Kind.Runtime = runtime
		if runtime == "podman" {
			fmt.Fprintf(os.Stderr, "note: generating for Podman (%s). Set kind.runtime in the definition to choose explicitly.\n", reason)
		}
	}

	errs, warns := validate(cfg)
	if len(errs) == 0 && *format == "terraform" {
		tfErrs, tfWarns := validateTerraform(cfg)
		errs, warns = append(errs, tfErrs...), append(warns, tfWarns...)
	}
	for _, w := range warns {
		fmt.Fprintln(os.Stderr, "warning:", w)
	}
	if len(errs) > 0 {
		fmt.Fprintf(os.Stderr, "error: %s is not a valid cluster definition:\n", *file)
		for _, e := range errs {
			fmt.Fprintln(os.Stderr, "  -", e)
		}
		os.Exit(exitInvalid)
	}

	tools := requiredTools(cfg, *format)
	if missing := missingTools(tools); len(missing) > 0 {
		level := "error"
		if *skipTools {
			level = "warning"
		}
		fmt.Fprintf(os.Stderr, "%s: %d tool(s) required for provider %q (%s) are not installed or not in PATH:\n",
			level, len(missing), cfg.Provider, *format)
		for _, t := range missing {
			fmt.Fprintf(os.Stderr, "  - %s (%s)\n      install it from: %s\n", t.Binary, t.Purpose, t.URL)
		}
		if !*skipTools {
			fmt.Fprintln(os.Stderr, "Nothing was written. Install the tools, or pass -skip-tool-check to generate anyway.")
			os.Exit(exitMissingTools)
		}
	}

	if *format == "terraform" {
		dir := *out
		if dir == "" {
			dir = "terraform-" + cfg.Name
		}
		files, err := writeTerraform(cfg, *file, dir)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		for _, f := range files {
			fmt.Fprintln(os.Stderr, "wrote", f)
		}
		fmt.Fprintf(os.Stderr, "next: cd %s && terraform init && terraform plan\n", dir)
		return
	}

	script := generate(cfg, *file, tools)
	if *out == "-" {
		fmt.Print(script)
		return
	}
	path := *out
	if path == "" {
		path = "create-" + cfg.Name + ".sh"
	}
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "wrote %s - run it with: bash %s\n", path, path)
}
