package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func copyDir(srcDir, dstDir string) error {
	return filepath.Walk(srcDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(srcDir, path)
		if err != nil {
			return err
		}
		targetPath := filepath.Join(dstDir, rel)
		if info.IsDir() {
			return os.MkdirAll(targetPath, 0755)
		}
		return copyFile(path, targetPath)
	})
}

func main() {
	var (
		catalogDir  = flag.String("catalog", "/catalog", "Path to skill catalog root")
		persona     = flag.String("persona", "", "Persona name to sync (e.g. sre-observer, security-auditor, finops-optimizer)")
		destination = flag.String("dest", "/opt/data", "Destination path for agent runtime")
		verifyOnly  = flag.Bool("verify", false, "Verify catalog integrity and exit")
	)
	flag.Parse()

	if *verifyOnly {
		fmt.Printf("Verifying catalog at %s...\n", *catalogDir)
		personasDir := filepath.Join(*catalogDir, "personas")
		skillsDir := filepath.Join(*catalogDir, "skills")

		if _, err := os.Stat(personasDir); err != nil {
			fmt.Fprintf(os.Stderr, "Missing personas directory: %v\n", err)
			os.Exit(1)
		}
		if _, err := os.Stat(skillsDir); err != nil {
			fmt.Fprintf(os.Stderr, "Missing skills directory: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("Catalog structure verified successfully.")
		return
	}

	if *persona == "" {
		// Fallback to environment variable
		*persona = os.Getenv("PERSONA_NAME")
	}

	if *persona == "" {
		fmt.Println("No persona specified (--persona or PERSONA_NAME). Standing by.")
		return
	}

	fmt.Printf("Syncing persona '%s' to destination '%s'\n", *persona, *destination)

	// 1. Copy persona definition
	personaFile := filepath.Join(*catalogDir, "personas", fmt.Sprintf("%s.md", *persona))
	if _, err := os.Stat(personaFile); err == nil {
		destPersona := filepath.Join(*destination, "persona.md")
		if err := copyFile(personaFile, destPersona); err != nil {
			fmt.Fprintf(os.Stderr, "Error copying persona: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Copied %s -> %s\n", personaFile, destPersona)
	}

	// 2. Copy matching skills
	skillsBase := filepath.Join(*catalogDir, "skills")
	category := strings.Split(*persona, "-")[0] // e.g. "sre", "security", "finops"
	categoryDir := filepath.Join(skillsBase, category)

	if _, err := os.Stat(categoryDir); err == nil {
		destSkills := filepath.Join(*destination, "skills", "custom")
		if err := copyDir(categoryDir, destSkills); err != nil {
			fmt.Fprintf(os.Stderr, "Error copying skills: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Copied skills from %s -> %s\n", categoryDir, destSkills)
	}

	fmt.Println("Persona and skill loader completed successfully.")
}
