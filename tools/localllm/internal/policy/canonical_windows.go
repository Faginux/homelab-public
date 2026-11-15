package policy

import (
	"errors"
	"os"
	"strings"

	"golang.org/x/sys/windows"
)

// openFile opens the path and reads the facts from the handle. The standard
// library cannot give the real path here: since Go 1.23,
// filepath.EvalSymlinks does not resolve a junction, but os.Open follows it.
func openFile(path string) (*os.File, fileFacts, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fileFacts{}, openError(path, err)
	}
	facts, err := handleFacts(f)
	if err != nil {
		f.Close()
		return nil, fileFacts{}, deny(CodeOpenFailed, path, err.Error())
	}
	return f, facts.fileFacts, nil
}

// canonicalDir returns the real path of a directory.
func canonicalDir(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	facts, err := handleFacts(f)
	if err != nil {
		return "", err
	}
	if !facts.directory {
		return "", errors.New("the root is not a directory")
	}
	return facts.canonical, nil
}

type handleInfo struct {
	fileFacts
	directory bool
}

func handleFacts(f *os.File) (handleInfo, error) {
	handle := windows.Handle(f.Fd())

	fileType, err := windows.GetFileType(handle)
	if err != nil {
		return handleInfo{}, errors.New("the file type is not available")
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		return handleInfo{}, errors.New("the file attributes are not available")
	}
	canonical, err := finalPath(handle)
	if err != nil {
		return handleInfo{}, err
	}

	directory := info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0
	return handleInfo{
		fileFacts: fileFacts{
			canonical: canonical,
			regular:   fileType == windows.FILE_TYPE_DISK && !directory,
			links:     info.NumberOfLinks,
			size:      int64(info.FileSizeHigh)<<32 | int64(info.FileSizeLow),
		},
		directory: directory,
	}, nil
}

// finalPath asks the system for the real path of an open handle: links are
// resolved, short names are long, and the case is the case on the disk.
func finalPath(handle windows.Handle) (string, error) {
	buf := make([]uint16, 512)
	for {
		n, err := windows.GetFinalPathNameByHandle(handle, &buf[0], uint32(len(buf)), 0)
		if err != nil {
			return "", errors.New("the real path is not available")
		}
		if n < uint32(len(buf)) {
			break
		}
		buf = make([]uint16, n+1)
	}
	path := windows.UTF16ToString(buf)

	const extendedPrefix = `\\?\`
	path = strings.TrimPrefix(path, extendedPrefix)
	if !driveAbsolute.MatchString(path) {
		// For example \\?\UNC\server\share: the file is not on a local drive.
		return "", errors.New("the real path is not on a local drive")
	}
	return path, nil
}
