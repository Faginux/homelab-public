package policy

import (
	"bytes"
	"strings"
	"unicode/utf8"
)

// binaryShare is the divisor of the limit: input is binary when more than
// one byte in binaryShare is not text.
const binaryShare = 20

// Text checks that data is text and returns it as valid UTF-8. A NUL byte
// means binary data (this includes UTF-16). A small number of bad bytes is
// permitted, because a log can contain text in an old code page: each bad
// byte becomes U+FFFD.
func Text(data []byte) (string, error) {
	data = bytes.TrimPrefix(data, []byte("\xEF\xBB\xBF"))
	if bytes.IndexByte(data, 0) >= 0 {
		return "", deny(CodeBinary, "", "the input contains a NUL byte")
	}
	bad := 0
	for i := 0; i < len(data); {
		r, size := utf8.DecodeRune(data[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			bad++
		case r < 0x20 && !strings.ContainsRune("\t\n\r\f\x1b", r):
			bad++
		}
		i += size
	}
	if bad*binaryShare > len(data) {
		return "", deny(CodeBinary, "", "too many bytes of the input are not text")
	}
	return strings.ToValidUTF8(string(data), "�"), nil
}
