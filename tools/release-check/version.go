package main

import (
	"regexp"
	"strconv"
)

// A full version tag: optional "v", 3 or 4 numeric parts, optional variant suffix
// ("-full", "-cuda"). A tag with a pre-release suffix ("-rc1") parses too, but its
// suffix never equals the suffix of a pin, so it never becomes a candidate.
var versionTagRe = regexp.MustCompile(`^(v?)(\d+(?:\.\d+){2,3})(-[A-Za-z0-9._-]+)?$`)

type version struct {
	Prefix string
	Nums   []int
	Suffix string
}

func parseVersion(tag string) (version, bool) {
	m := versionTagRe.FindStringSubmatch(tag)
	if m == nil {
		return version{}, false
	}
	var nums []int
	start := 0
	digits := m[2]
	for i := 0; i <= len(digits); i++ {
		if i == len(digits) || digits[i] == '.' {
			n, err := strconv.Atoi(digits[start:i])
			if err != nil {
				return version{}, false
			}
			nums = append(nums, n)
			start = i + 1
		}
	}
	return version{Prefix: m[1], Nums: nums, Suffix: m[3]}, true
}

// sameShape tells if two versions can be compared: same "v" prefix, same variant
// suffix, same number of parts.
func (v version) sameShape(o version) bool {
	return v.Prefix == o.Prefix && v.Suffix == o.Suffix && len(v.Nums) == len(o.Nums)
}

// newerThan compares the numeric parts. Call it only after sameShape.
func (v version) newerThan(o version) bool {
	for i := range v.Nums {
		if v.Nums[i] != o.Nums[i] {
			return v.Nums[i] > o.Nums[i]
		}
	}
	return false
}

func (v version) String() string {
	out := v.Prefix
	for i, n := range v.Nums {
		if i > 0 {
			out += "."
		}
		out += strconv.Itoa(n)
	}
	return out + v.Suffix
}

// Track rules: which newer versions count as a safe update.
const (
	trackMajor   = "major"   // same first part (2.11.4 -> 2.12.0)
	trackMinor   = "minor"   // same first two parts (8.0.34 -> 8.0.35)
	trackAny     = "any"     // any newer version (calendar versions)
	trackRebuild = "rebuild" // same tag, new digest only
)

func validTrack(t string) bool {
	switch t {
	case trackMajor, trackMinor, trackAny, trackRebuild:
		return true
	}
	return false
}

func inTrack(track string, pin, cand version) bool {
	switch track {
	case trackMajor:
		return cand.Nums[0] == pin.Nums[0]
	case trackMinor:
		return cand.Nums[0] == pin.Nums[0] && cand.Nums[1] == pin.Nums[1]
	case trackAny:
		return true
	}
	return false
}

// pickCandidates returns the highest newer version in the track ("safe") and the
// highest newer version with a higher first part that is outside the track ("major").
// Both are nil when there is none.
func pickCandidates(track string, pin version, tags []string) (safe, major *version) {
	for _, tag := range tags {
		cand, ok := parseVersion(tag)
		if !ok || !pin.sameShape(cand) || !cand.newerThan(pin) {
			continue
		}
		c := cand
		if inTrack(track, pin, c) {
			if safe == nil || c.newerThan(*safe) {
				safe = &c
			}
		} else if c.Nums[0] > pin.Nums[0] {
			if major == nil || c.newerThan(*major) {
				major = &c
			}
		}
	}
	return safe, major
}
