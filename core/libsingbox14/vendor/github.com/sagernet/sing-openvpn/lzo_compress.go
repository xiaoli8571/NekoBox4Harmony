// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Maxim Levchenko (WoozyMasta)
// Adapted from github.com/woozymasta/lzo.

package openvpn

const (
	lzoMaxOffsetM2 = 0x0800
	lzoMaxOffsetM3 = 0x4000
	lzoMaxOffsetM4 = 0xbfff
	lzoMaxLengthM2 = 8
	lzoMaxLengthM4 = 9
	lzoMarkerM3    = 32
	lzoMarkerM4    = 16
	lzoDictBits    = 14
	lzoDictMask    = (1 << lzoDictBits) - 1
	lzoDictHigh    = (lzoDictMask >> 1) + 1
)

func compressLZOBlock(input []byte) []byte {
	inputLength := len(input)
	literalTailSize := inputLength
	var output []byte
	if inputLength > lzoMaxLengthM2+5 {
		output, literalTailSize = compressLZOBlockCore(input)
	}
	if literalTailSize > 0 {
		literalStart := inputLength - literalTailSize
		output = appendLZOLiteral(output, input[literalStart:])
	}
	return append(output, lzoMarkerM4|1, 0, 0)
}

func compressLZOBlockCore(input []byte) (output []byte, literalTailSize int) {
	inputLength := len(input)
	inputLimit := inputLength - lzoMaxLengthM2 - 5
	dictionary := make([]int, 1<<lzoDictBits)
	literalStart := 0
	inputPosition := 4

	for {
		key := int(input[inputPosition+3])
		key = (key << 6) ^ int(input[inputPosition+2])
		key = (key << 5) ^ int(input[inputPosition+1])
		key = (key << 5) ^ int(input[inputPosition])
		dictionaryIndex := ((0x21 * key) >> 5) & lzoDictMask
		matched := false

		for attempt := range 2 {
			matchPosition, matchOffset := findLZOCandidate(dictionary, input, inputPosition, dictionaryIndex)
			tryMatch := matchPosition >= 0 &&
				(matchOffset <= lzoMaxOffsetM2 || input[matchPosition+3] == input[inputPosition+3])
			if tryMatch &&
				input[matchPosition] == input[inputPosition] &&
				input[matchPosition+1] == input[inputPosition+1] &&
				input[matchPosition+2] == input[inputPosition+2] {
				dictionary[dictionaryIndex] = inputPosition + 1
				if inputPosition != literalStart {
					output = appendLZOLiteral(output, input[literalStart:inputPosition])
					literalStart = inputPosition
				}

				inputPosition += 3
				var matchLength int
				for matchLength = 3; matchLength < 9; matchLength++ {
					inputPosition++
					if input[matchPosition+matchLength] != input[inputPosition-1] {
						break
					}
				}

				if matchLength < 9 {
					inputPosition--
					matchLength = inputPosition - literalStart
					switch {
					case matchOffset <= lzoMaxOffsetM2:
						matchOffset--
						output = append(output,
							byte(((matchLength-1)<<5)|((matchOffset&7)<<2)),
							byte(matchOffset>>3),
						)
					case matchOffset <= lzoMaxOffsetM3:
						matchOffset--
						output = append(output,
							byte(lzoMarkerM3|(matchLength-2)),
							byte((matchOffset&63)<<2),
							byte(matchOffset>>6),
						)
					default:
						matchOffset -= 0x4000
						output = append(output,
							byte(lzoMarkerM4|((matchOffset&0x4000)>>11)|(matchLength-2)),
							byte((matchOffset&63)<<2),
							byte(matchOffset>>6),
						)
					}
				} else {
					matchPosition += lzoMaxLengthM2 + 1
					for inputPosition < inputLength && input[matchPosition] == input[inputPosition] {
						matchPosition++
						inputPosition++
					}
					matchLength = inputPosition - literalStart
					if matchOffset <= lzoMaxOffsetM3 {
						matchOffset--
						if matchLength <= 33 {
							output = append(output, byte(lzoMarkerM3|(matchLength-2)))
						} else {
							output = append(output, byte(lzoMarkerM3))
							output = appendLZOMultiple(output, matchLength-33)
						}
					} else {
						matchOffset -= 0x4000
						if matchLength <= lzoMaxLengthM4 {
							output = append(output, byte(lzoMarkerM4|((matchOffset&0x4000)>>11)|(matchLength-2)))
						} else {
							output = append(output, byte(lzoMarkerM4|((matchOffset&0x4000)>>11)))
							output = appendLZOMultiple(output, matchLength-lzoMaxLengthM4)
						}
					}
					output = append(output, byte((matchOffset&63)<<2), byte(matchOffset>>6))
				}

				literalStart = inputPosition
				matched = true
				break
			}
			if attempt == 0 {
				dictionaryIndex = (dictionaryIndex & (lzoDictMask & 0x7ff)) ^ (lzoDictHigh | 0x1f)
			}
		}

		if matched {
			if inputPosition >= inputLimit {
				break
			}
			continue
		}
		dictionary[dictionaryIndex] = inputPosition + 1
		inputPosition += 1 + (inputPosition-literalStart)>>5
		if inputPosition >= inputLimit {
			break
		}
	}

	return output, inputLength - literalStart
}

func findLZOCandidate(dictionary []int, input []byte, inputPosition int, dictionaryIndex int) (int, int) {
	matchPosition := dictionary[dictionaryIndex] - 1
	if matchPosition < 0 || inputPosition == matchPosition || inputPosition-matchPosition > lzoMaxOffsetM4 {
		return -1, 0
	}
	matchOffset := inputPosition - matchPosition
	if matchOffset <= lzoMaxOffsetM2 || input[matchPosition+3] == input[inputPosition+3] {
		return matchPosition, matchOffset
	}
	return -1, 0
}

func appendLZOLiteral(output []byte, literal []byte) []byte {
	literalCount := len(literal)
	if literalCount == 0 {
		return output
	}
	switch {
	case len(output) == 0 && literalCount <= 238:
		output = append(output, byte(17+literalCount))
	case literalCount <= 3:
		output[len(output)-2] |= byte(literalCount)
	case literalCount <= 18:
		output = append(output, byte(literalCount-3))
	default:
		output = append(output, 0)
		output = appendLZOMultiple(output, literalCount-18)
	}
	return append(output, literal...)
}

func appendLZOMultiple(output []byte, value int) []byte {
	for value > 255 {
		output = append(output, 0)
		value -= 255
	}
	return append(output, byte(value))
}
