// This file contains a Go port of OpenConnect 9.21, lzs.c.
//
// Copyright © 2008-2015 Intel Corporation.
// Author: David Woodhouse <dwmw2@infradead.org>
//
// OpenConnect is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License version 2.1, as published
// by the Free Software Foundation. OpenConnect is distributed without any
// warranty; without even the implied warranty of merchantability or fitness
// for a particular purpose.
package openconnect

import (
	"bytes"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	lzsHashTableSize    = 1 << 16
	lzsMaximumHistory   = 1 << 11
	lzsInvalidOffset    = uint16(0xffff)
	lzsMaximumInputSize = int(lzsInvalidOffset) + 1
)

type lzsCompressor struct {
	hashTable [lzsHashTableSize]uint16
	hashChain [lzsMaximumHistory]uint16
}

type lzsBitReader struct {
	source    []byte
	bitOffset int
}

type lzsBitWriter struct {
	destination []byte
	bitOffset   int
}

var lzsCompressorPool = sync.Pool{
	New: func() any {
		return new(lzsCompressor)
	},
}

func compressLZS(destination []byte, source []byte) (int, error) {
	compressor := lzsCompressorPool.Get().(*lzsCompressor)
	written, err := compressor.compress(destination, source)
	lzsCompressorPool.Put(compressor)
	return written, err
}

func (c *lzsCompressor) compress(destination []byte, source []byte) (int, error) {
	if len(source) > lzsMaximumInputSize {
		return 0, E.New("LZS input exceeds 65536 bytes")
	}
	for i := range c.hashTable {
		c.hashTable[i] = lzsInvalidOffset
	}
	writer := lzsBitWriter{destination: destination}
	inputPosition := 0
	for inputPosition < len(source)-2 {
		hash := lzsHash(source, inputPosition)
		candidateOffset := c.hashTable[hash]
		c.hashChain[inputPosition&(lzsMaximumHistory-1)] = candidateOffset
		c.hashTable[hash] = uint16(inputPosition)
		if candidateOffset == lzsInvalidOffset || int(candidateOffset)+lzsMaximumHistory <= inputPosition {
			err := writer.write(uint32(source[inputPosition]), 9)
			if err != nil {
				return 0, err
			}
			inputPosition++
			continue
		}

		longestMatchLength := 2
		longestMatchPosition := int(candidateOffset)
		for candidateOffset != lzsInvalidOffset && int(candidateOffset)+lzsMaximumHistory > inputPosition {
			candidatePosition := int(candidateOffset)
			currentEnd := inputPosition + longestMatchLength + 1
			candidateEnd := candidatePosition + longestMatchLength + 1
			if currentEnd <= len(source) && candidateEnd <= len(source) &&
				bytes.Equal(source[candidatePosition+2:candidateEnd], source[inputPosition+2:currentEnd]) {
				longestMatchPosition = candidatePosition
				matchLength := longestMatchLength + 1
				for inputPosition+matchLength < len(source) && source[inputPosition+matchLength] == source[candidatePosition+matchLength] {
					matchLength++
				}
				longestMatchLength = matchLength
				if inputPosition+longestMatchLength == len(source) {
					break
				}
			}
			candidateOffset = c.hashChain[candidatePosition&(lzsMaximumHistory-1)]
		}

		err := writeLZSMatch(&writer, inputPosition-longestMatchPosition, longestMatchLength)
		if err != nil {
			return 0, err
		}
		if inputPosition+longestMatchLength >= len(source)-2 {
			inputPosition += longestMatchLength
			break
		}
		inputPosition++
		for remainingMatchLength := longestMatchLength - 1; remainingMatchLength > 0; remainingMatchLength-- {
			hash = lzsHash(source, inputPosition)
			c.hashChain[inputPosition&(lzsMaximumHistory-1)] = c.hashTable[hash]
			c.hashTable[hash] = uint16(inputPosition)
			inputPosition++
		}
	}

	if inputPosition == len(source)-2 {
		hash := lzsHash(source, inputPosition)
		candidateOffset := c.hashTable[hash]
		if candidateOffset != lzsInvalidOffset && int(candidateOffset)+lzsMaximumHistory > inputPosition {
			err := writeLZSMatch(&writer, inputPosition-int(candidateOffset), 2)
			if err != nil {
				return 0, err
			}
		} else {
			err := writer.write(uint32(source[inputPosition]), 9)
			if err != nil {
				return 0, err
			}
			err = writer.write(uint32(source[inputPosition+1]), 9)
			if err != nil {
				return 0, err
			}
		}
	} else if inputPosition == len(source)-1 {
		err := writer.write(uint32(source[inputPosition]), 9)
		if err != nil {
			return 0, err
		}
	}
	err := writer.write(0xc000, 16)
	if err != nil {
		return 0, err
	}
	return writer.bitOffset / 8, nil
}

func lzsHash(source []byte, position int) uint16 {
	return uint16(source[position])<<8 | uint16(source[position+1])
}

func writeLZSMatch(writer *lzsBitWriter, offset int, length int) error {
	var err error
	if offset < 0x80 {
		err = writer.write(uint32(0x180|offset), 9)
	} else {
		err = writer.write(uint32(0x1000|offset), 13)
	}
	if err != nil {
		return err
	}
	if length < 5 {
		return writer.write(uint32(length-2), 2)
	}
	if length < 8 {
		return writer.write(uint32(length+7), 4)
	}
	remainingLength := length + 7
	for remainingLength >= 30 {
		err = writer.write(0xff, 8)
		if err != nil {
			return err
		}
		remainingLength -= 30
	}
	if remainingLength >= 15 {
		return writer.write(uint32(0xf0+remainingLength-15), 8)
	}
	return writer.write(uint32(remainingLength), 4)
}

func (w *lzsBitWriter) write(value uint32, bitCount int) error {
	if bitCount < 0 || bitCount > 32 || w.bitOffset+bitCount > len(w.destination)*8 {
		return E.New("LZS output exceeds destination capacity")
	}
	for i := bitCount - 1; i >= 0; i-- {
		byteIndex := w.bitOffset / 8
		bitIndex := 7 - w.bitOffset%8
		mask := byte(1 << bitIndex)
		if value&(1<<i) != 0 {
			w.destination[byteIndex] |= mask
		} else {
			w.destination[byteIndex] &^= mask
		}
		w.bitOffset++
	}
	return nil
}

func decompressLZS(destination []byte, source []byte) (int, error) {
	reader := lzsBitReader{source: source}
	written := 0
	for {
		code, err := reader.read(9)
		if err != nil {
			return 0, err
		}
		if code < 0x100 {
			if written >= len(destination) {
				return 0, E.New("LZS output exceeds destination capacity")
			}
			destination[written] = byte(code)
			written++
			continue
		}
		if code == 0x180 {
			return written, nil
		}
		offset := int(code & 0x7f)
		if code < 0x180 {
			lowOffset, readErr := reader.read(4)
			if readErr != nil {
				return 0, readErr
			}
			offset = offset<<4 | int(lowOffset)
		}
		if offset == 0 || offset > written {
			return 0, E.New("invalid LZS match offset")
		}

		lengthCode, readErr := reader.read(2)
		if readErr != nil {
			return 0, readErr
		}
		length := int(lengthCode) + 2
		if lengthCode == 3 {
			lengthCode, readErr = reader.read(2)
			if readErr != nil {
				return 0, readErr
			}
			length = int(lengthCode) + 5
			if lengthCode == 3 {
				length = 8
				for {
					lengthCode, readErr = reader.read(4)
					if readErr != nil {
						return 0, readErr
					}
					addition := int(lengthCode)
					if addition > len(destination)-written-length {
						return 0, E.New("LZS output exceeds destination capacity")
					}
					length += addition
					if lengthCode != 15 {
						break
					}
				}
			}
		}
		if length > len(destination)-written {
			return 0, E.New("LZS output exceeds destination capacity")
		}
		for length > 0 {
			destination[written] = destination[written-offset]
			written++
			length--
		}
	}
}

func (r *lzsBitReader) read(bitCount int) (uint32, error) {
	if bitCount < 0 || bitCount > 32 || r.bitOffset+bitCount > len(r.source)*8 {
		return 0, E.New("truncated LZS bitstream")
	}
	var value uint32
	for range bitCount {
		byteIndex := r.bitOffset / 8
		bitIndex := 7 - r.bitOffset%8
		value = value<<1 | uint32(r.source[byteIndex]>>bitIndex&1)
		r.bitOffset++
	}
	return value, nil
}
