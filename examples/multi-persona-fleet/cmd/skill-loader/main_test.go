package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCopyFile(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "copyfile-test")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tempDir)

	srcFile := filepath.Join(tempDir, "src.txt")
	dstFile := filepath.Join(tempDir, "sub", "dst.txt")
	content := "hello world from skill loader test"

	if err := os.WriteFile(srcFile, []byte(content), 0644); err != nil {
		t.Fatalf("Failed to write source file: %v", err)
	}

	if err := copyFile(srcFile, dstFile); err != nil {
		t.Fatalf("copyFile failed: %v", err)
	}

	readBack, err := os.ReadFile(dstFile)
	if err != nil {
		t.Fatalf("Failed to read dst file: %v", err)
	}

	if string(readBack) != content {
		t.Errorf("Content mismatch: expected %q, got %q", content, string(readBack))
	}
}

func TestCopyDir(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "copydir-test")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tempDir)

	srcDir := filepath.Join(tempDir, "source")
	dstDir := filepath.Join(tempDir, "dest")

	if err := os.MkdirAll(filepath.Join(srcDir, "category", "nested"), 0755); err != nil {
		t.Fatalf("Failed to create nested dir: %v", err)
	}

	file1 := filepath.Join(srcDir, "category", "file1.txt")
	file2 := filepath.Join(srcDir, "category", "nested", "file2.txt")
	if err := os.WriteFile(file1, []byte("file1 content"), 0644); err != nil {
		t.Fatalf("Failed to write file1: %v", err)
	}
	if err := os.WriteFile(file2, []byte("file2 content"), 0644); err != nil {
		t.Fatalf("Failed to write file2: %v", err)
	}

	if err := copyDir(srcDir, dstDir); err != nil {
		t.Fatalf("copyDir failed: %v", err)
	}

	dstFile1 := filepath.Join(dstDir, "category", "file1.txt")
	dstFile2 := filepath.Join(dstDir, "category", "nested", "file2.txt")

	if _, err := os.Stat(dstFile1); err != nil {
		t.Errorf("Destination file1 missing: %v", err)
	}
	if _, err := os.Stat(dstFile2); err != nil {
		t.Errorf("Destination file2 missing: %v", err)
	}
}
