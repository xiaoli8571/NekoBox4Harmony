package anytls

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/hex"
	"math/big"
	"strconv"
	"strings"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	paddingCheckMark = -1
	maxPaddingSize   = 1 << 20
)

var DefaultPaddingScheme = []byte(`stop=8
0=30-30
1=100-400
2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
3=9-9,500-1000
4=500-1000
5=500-1000
6=500-1000
7=500-1000`)

type paddingRange struct {
	minSize int
	maxSize int
}

type paddingFactory struct {
	rawScheme []byte
	md5Sum    string
	stop      uint32
	records   map[uint32][]paddingRange
}

func newPaddingFactory(rawScheme []byte) (*paddingFactory, error) {
	scheme := parseSettings(rawScheme)
	if len(scheme) == 0 {
		return nil, ErrPaddingScheme
	}
	// sing-anytls 0.0.11 padding.NewPaddingFactory converts stop with an unchecked
	// uint32 cast, so a negative stop means "never stop padding" on the wire.
	stop, err := strconv.Atoi(scheme["stop"])
	if err != nil {
		return nil, E.Extend(ErrPaddingScheme, "parse stop: ", err)
	}
	sum := md5.Sum(rawScheme)
	factory := &paddingFactory{
		rawScheme: rawScheme,
		md5Sum:    hex.EncodeToString(sum[:]),
		stop:      uint32(stop),
		records:   make(map[uint32][]paddingRange),
	}
	for key, value := range scheme {
		packet, parseErr := strconv.ParseUint(key, 10, 32)
		if parseErr != nil || strconv.FormatUint(packet, 10) != key {
			continue
		}
		var ranges []paddingRange
		for item := range strings.SplitSeq(value, ",") {
			if item == "c" {
				ranges = append(ranges, paddingRange{minSize: paddingCheckMark})
				continue
			}
			minText, maxText, found := strings.Cut(item, "-")
			if !found {
				continue
			}
			minSize, minErr := strconv.Atoi(minText)
			if minErr != nil {
				continue
			}
			maxSize, maxErr := strconv.Atoi(maxText)
			if maxErr != nil {
				continue
			}
			if minSize > maxSize {
				minSize, maxSize = maxSize, minSize
			}
			if minSize <= 0 || maxSize > maxPaddingSize {
				continue
			}
			ranges = append(ranges, paddingRange{minSize: minSize, maxSize: maxSize})
		}
		if len(ranges) > 0 {
			factory.records[uint32(packet)] = ranges
		}
	}
	return factory, nil
}

func (f *paddingFactory) GenerateRecordPayloadSizes(packet uint32) []int {
	ranges := f.records[packet]
	if len(ranges) == 0 {
		return nil
	}
	sizes := make([]int, 0, len(ranges))
	for _, item := range ranges {
		switch {
		case item.minSize == paddingCheckMark:
			sizes = append(sizes, paddingCheckMark)
		case item.maxSize > item.minSize:
			offset := common.Must1(rand.Int(rand.Reader, big.NewInt(int64(item.maxSize-item.minSize))))
			sizes = append(sizes, item.minSize+int(offset.Int64()))
		default:
			sizes = append(sizes, item.minSize)
		}
	}
	return sizes
}

func (f *paddingFactory) GenerateHandshakePaddingSize() int {
	sizes := f.GenerateRecordPayloadSizes(0)
	if len(sizes) == 0 || sizes[0] < 0 {
		return 0
	}
	return sizes[0]
}
