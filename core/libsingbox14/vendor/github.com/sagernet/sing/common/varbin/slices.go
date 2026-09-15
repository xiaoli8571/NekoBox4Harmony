package varbin

import (
	"slices"

	"github.com/sagernet/sing/common/binary"
)

type BaseData interface {
	~bool | ~int8 | ~uint8 | ~int16 | ~uint16 | ~int32 | ~uint32 | ~int64 | ~uint64 | ~float32 | ~float64
}

func ReadSlice[T BaseData](reader Reader, order binary.ByteOrder) ([]T, error) {
	count, err := binary.ReadUvarint(reader)
	if err != nil {
		return nil, err
	}
	return ReadSliceCount[T](reader, order, count)
}

func ReadSliceCount[T BaseData](reader Reader, order binary.ByteOrder, count uint64) ([]T, error) {
	var result []T
	for uint64(len(result)) < count {
		result = slices.Grow(result, 1)
		chunkCount := min(count-uint64(len(result)), uint64(cap(result)-len(result)))
		start := len(result)
		result = result[:uint64(start)+chunkCount]
		err := binary.Read(reader, order, result[start:])
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}
