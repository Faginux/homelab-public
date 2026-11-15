package gpu

import (
	"reflect"
	"testing"
)

func TestParse(t *testing.T) {
	tests := []struct {
		name    string
		out     string
		want    Status
		wantErr bool
	}{
		{"one GPU", "12288, 982, 11103\r\n", Status{12288, 982, 11103}, false},
		{"no spaces", "12288,982,11103\n", Status{12288, 982, 11103}, false},
		{"two GPUs: the first counts", "12288, 982, 11103\n8192, 100, 8092\n", Status{12288, 982, 11103}, false},
		{"empty output", "", Status{}, true},
		{"two fields", "12288, 982\n", Status{}, true},
		{"four fields", "12288, 982, 11103, 5\n", Status{}, true},
		{"not a number", "12288, [N/A], 11103\n", Status{}, true},
		{"negative number", "12288, -1, 11103\n", Status{}, true},
		{"error text", "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.\n", Status{}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parse(tt.out)
			if (err != nil) != tt.wantErr {
				t.Fatalf("parse error = %v, wantErr %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("parse = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestFits(t *testing.T) {
	tests := []struct {
		name               string
		free, need, margin int
		want               bool
	}{
		{"much free memory", 11103, 3158, 1024, true},
		{"exactly the need plus the margin", 4182, 3158, 1024, true},
		{"one MiB less than the need plus the margin", 4181, 3158, 1024, false},
		{"the need fits but the margin does not", 3200, 3158, 1024, false},
		{"no free memory", 0, 3158, 1024, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Fits(tt.free, tt.need, tt.margin); got != tt.want {
				t.Errorf("Fits(%d, %d, %d) = %v, want %v", tt.free, tt.need, tt.margin, got, tt.want)
			}
		})
	}
}

func TestArgumentsAreConstant(t *testing.T) {
	want := []string{
		"--query-gpu=memory.total,memory.used,memory.free",
		"--format=csv,noheader,nounits",
	}
	if !reflect.DeepEqual(smiArgs, want) {
		t.Errorf("smiArgs = %v, want %v", smiArgs, want)
	}
}
