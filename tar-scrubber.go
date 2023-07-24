package main

// TODO this should probably be part of bashbrew itself

import (
	"archive/tar"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
)

func main() {
	tr := tar.NewReader(os.Stdin)

	var out io.Writer = os.Stdout
	if len(os.Args) >= 2 && os.Args[1] == "--sha256" {
		h := sha256.New()
		out = h
		defer func() {
			fmt.Printf("%x\n", h.Sum(nil))
		}()
	}

	tw := tar.NewWriter(out)
	defer tw.Flush() // note: flush instead of close to avoid the empty block at EOF

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			panic(err)
		}
		newHdr := &tar.Header{
			Typeflag: hdr.Typeflag,
			Name:     hdr.Name,
			Linkname: hdr.Linkname,
			Size:     hdr.Size,
			Mode:     hdr.Mode,
			Devmajor: hdr.Devmajor,
			Devminor: hdr.Devminor,
		}
		if err := tw.WriteHeader(newHdr); err != nil {
			panic(err)
		}
		if _, err := io.Copy(tw, tr); err != nil {
			panic(err)
		}
	}
}
