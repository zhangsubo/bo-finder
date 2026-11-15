// Package mlguard implements the embedded zero-CGO neural classifier and 3-layer AI funnel
// for DeskSide Security Gateway.
//
// Embedded weights (`weights_tiny_fp16.bin`) are derived from `bardsai/password-detector` (`tiny`),
// licensed under Apache License 2.0 (https://huggingface.co/bardsai/password-detector).
package mlguard

import (
	_ "embed"
	"encoding/binary"
	"errors"
	"math"
	"sync"
)

const (
	leftBytes  = 64
	candBytes  = 96
	rightBytes = 32
	seqLen     = leftBytes + candBytes + rightBytes + 2 // 194

	tokPad  = 0
	tokSep1 = 1
	tokSep2 = 2
	vocabSz = 259
)

var secretTypes = [...]string{
	"none",
	"password",
	"api_key",
	"token",
	"private_key",
	"generic",
}

//go:embed weights_tiny_fp16.bin
var embeddedTinyWeights []byte

var (
	fp16LUT     [65536]float32
	defaultOnce sync.Once
	defaultCNN  *TinyCNN
	defaultErr  error
)

func init() {
	for u := 0; u < 65536; u++ {
		fp16LUT[u] = decodeFP16Slow(uint16(u))
	}
}

func decodeFP16Slow(h uint16) float32 {
	sign := uint32(h>>15) & 0x1
	exp := uint32(h>>10) & 0x1f
	mant := uint32(h & 0x03ff)

	var bits uint32
	switch exp {
	case 0:
		if mant == 0 {
			bits = sign << 31
		} else {
			// Subnormal FP16 -> normalized FP32
			e := uint32(127 - 14)
			for (mant & 0x0400) == 0 {
				mant <<= 1
				e--
			}
			mant &= 0x03ff
			bits = (sign << 31) | (e << 23) | (mant << 13)
		}
	case 31:
		bits = (sign << 31) | (0xff << 23) | (mant << 13)
	default:
		bits = (sign << 31) | ((exp + (127 - 15)) << 23) | (mant << 13)
	}
	return math.Float32frombits(bits)
}

type dilatedBlock struct {
	dilation int
	weight   []float32 // [ch, ch, 3]
	bias     []float32 // [ch]
}

// TinyCNN is a pure-Go byte-context 1D dilated residual CNN (`emb=24, ch=48, dilations=[1,2,4,8]`).
type TinyCNN struct {
	emb      int
	ch       int
	nTypes   int
	byteEmb  []float32 // [259 * emb]
	segEmb   []float32 // [4 * emb]
	inpW     []float32 // [ch * emb * 4]
	inpB     []float32 // [ch]
	blocks   []dilatedBlock
	headW    []float32 // [ch * (3*ch)]
	headB    []float32 // [ch]
	outW     []float32 // [ch]
	outB     float32
	typeOutW []float32 // [nTypes * ch]
	typeOutB []float32 // [nTypes]
}

type Prediction struct {
	Prob   float64 `json:"prob"`
	Kind   string  `json:"kind"`
	Model  string  `json:"model"`
	Reason string  `json:"reason,omitempty"`
}

func DefaultTinyCNN() (*TinyCNN, error) {
	defaultOnce.Do(func() {
		defaultCNN, defaultErr = loadTinyCNN(embeddedTinyWeights)
	})
	return defaultCNN, defaultErr
}

func loadTinyCNN(raw []byte) (*TinyCNN, error) {
	if len(raw) < 16 || string(raw[:4]) != "DSML" {
		return nil, errors.New("mlguard: invalid weight header")
	}
	ver := int(binary.LittleEndian.Uint16(raw[4:6]))
	emb := int(binary.LittleEndian.Uint16(raw[6:8]))
	ch := int(binary.LittleEndian.Uint16(raw[8:10]))
	nBlocks := int(binary.LittleEndian.Uint16(raw[10:12]))
	nTypes := int(binary.LittleEndian.Uint16(raw[12:14]))
	if ver != 1 || emb <= 0 || ch <= 0 || nBlocks != 4 || nTypes != len(secretTypes) {
		return nil, errors.New("mlguard: unexpected weight dimensions")
	}

	offset := 16
	readVec := func(n int) ([]float32, error) {
		need := n * 2
		if offset+need > len(raw) {
			return nil, errors.New("mlguard: truncated weight buffer")
		}
		out := make([]float32, n)
		for i := 0; i < n; i++ {
			u := binary.LittleEndian.Uint16(raw[offset+i*2 : offset+i*2+2])
			out[i] = fp16LUT[u]
		}
		offset += need
		return out, nil
	}

	m := &TinyCNN{emb: emb, ch: ch, nTypes: nTypes}
	var err error
	if m.byteEmb, err = readVec(vocabSz * emb); err != nil {
		return nil, err
	}
	if m.segEmb, err = readVec(4 * emb); err != nil {
		return nil, err
	}
	if m.inpW, err = readVec(ch * emb * 4); err != nil {
		return nil, err
	}
	if m.inpB, err = readVec(ch); err != nil {
		return nil, err
	}

	dilations := [4]int{1, 2, 4, 8}
	m.blocks = make([]dilatedBlock, nBlocks)
	for i := 0; i < nBlocks; i++ {
		w, errW := readVec(ch * ch * 3)
		if errW != nil {
			return nil, errW
		}
		b, errB := readVec(ch)
		if errB != nil {
			return nil, errB
		}
		m.blocks[i] = dilatedBlock{
			dilation: dilations[i],
			weight:   w,
			bias:     b,
		}
	}

	if m.headW, err = readVec(ch * 3 * ch); err != nil {
		return nil, err
	}
	if m.headB, err = readVec(ch); err != nil {
		return nil, err
	}
	if m.outW, err = readVec(ch); err != nil {
		return nil, err
	}
	outBSlice, err := readVec(1)
	if err != nil {
		return nil, err
	}
	m.outB = outBSlice[0]
	if m.typeOutW, err = readVec(nTypes * ch); err != nil {
		return nil, err
	}
	if m.typeOutB, err = readVec(nTypes); err != nil {
		return nil, err
	}
	return m, nil
}

// EncodeSpan converts `text` and byte span `[start, end)` into the fixed 194-token byte+segment window.
func EncodeSpan(text string, start, end int) (ids [seqLen]uint16, seg [seqLen]uint8) {
	if start < 0 {
		start = 0
	}
	if end > len(text) {
		end = len(text)
	}
	if start > end {
		start = end
	}

	leftStart := start - leftBytes
	if leftStart < 0 {
		leftStart = 0
	}
	left := text[leftStart:start]

	candRaw := text[start:end]
	var candHead, candTail string
	if len(candRaw) > candBytes {
		half := candBytes / 2
		candHead = candRaw[:half]
		candTail = candRaw[len(candRaw)-half:]
	} else {
		candHead = candRaw
	}

	rightEnd := end + rightBytes
	if rightEnd > len(text) {
		rightEnd = len(text)
	}
	right := text[end:rightEnd]

	// Right-align left context so candidate always starts at index 64.
	lOff := leftBytes - len(left)
	for i := 0; i < len(left); i++ {
		ids[lOff+i] = uint16(left[i]) + 3
		seg[lOff+i] = 1
	}

	ids[leftBytes] = tokSep1
	seg[leftBytes] = 2
	o := leftBytes + 1

	for i := 0; i < len(candHead); i++ {
		ids[o] = uint16(candHead[i]) + 3
		seg[o] = 2
		o++
	}
	for i := 0; i < len(candTail); i++ {
		ids[o] = uint16(candTail[i]) + 3
		seg[o] = 2
		o++
	}

	ids[o] = tokSep2
	seg[o] = 2
	o++

	for i := 0; i < len(right) && o < seqLen; i++ {
		ids[o] = uint16(right[i]) + 3
		seg[o] = 3
		o++
	}
	return ids, seg
}

func gelu32(x float32) float32 {
	const invSqrt2 = 0.7071067811865475
	return float32(0.5 * float64(x) * (1.0 + math.Erf(float64(x)*invSqrt2)))
}

// Predict scores byte span `[start, end)` inside `text` in ~0.15ms without CGO.
func (m *TinyCNN) Predict(text string, start, end int) Prediction {
	ids, seg := EncodeSpan(text, start, end)

	const (
		embDim = 24
		chDim  = 48
		outLen = 97 // (194 + 2*1 - 4) / 2 + 1
	)

	// 1. Byte + segment embeddings [194, 24]
	var embBuf [seqLen * embDim]float32
	for t := 0; t < seqLen; t++ {
		id := int(ids[t])
		if id >= vocabSz {
			id = tokPad
		}
		sg := int(seg[t]) & 3
		bBase := id * embDim
		sBase := sg * embDim
		dst := t * embDim
		for d := 0; d < embDim; d++ {
			embBuf[dst+d] = m.byteEmb[bBase+d] + m.segEmb[sBase+d]
		}
	}

	// 2. Stem Conv1d (kernel=4, stride=2, pad=1) + GELU -> x [48, 97]
	var x [chDim * outLen]float32
	for oc := 0; oc < chDim; oc++ {
		wOc := oc * embDim * 4
		bias := m.inpB[oc]
		xRow := oc * outLen
		for pos := 0; pos < outLen; pos++ {
			inStart := pos*2 - 1
			sum := bias
			for k := 0; k < 4; k++ {
				t := inStart + k
				if t < 0 || t >= seqLen {
					continue
				}
				eRow := t * embDim
				// inpW layout in PyTorch Conv1d is [out_ch, in_ch, kernel_size]
				for ic := 0; ic < embDim; ic++ {
					sum += embBuf[eRow+ic] * m.inpW[wOc+ic*4+k]
				}
			}
			x[xRow+pos] = gelu32(sum)
		}
	}

	// 3. Four residual dilated Conv1d blocks (kernel=3, pad=dil, dilation=dil)
	var next [chDim * outLen]float32
	for _, blk := range m.blocks {
		dil := blk.dilation
		for oc := 0; oc < chDim; oc++ {
			wOc := oc * chDim * 3
			bias := blk.bias[oc]
			dstRow := oc * outLen
			for pos := 0; pos < outLen; pos++ {
				p0 := pos - dil
				p1 := pos
				p2 := pos + dil
				sum := bias
				for ic := 0; ic < chDim; ic++ {
					srcRow := ic * outLen
					wBase := wOc + ic*3
					if p0 >= 0 {
						sum += x[srcRow+p0] * blk.weight[wBase]
					}
					sum += x[srcRow+p1] * blk.weight[wBase+1]
					if p2 < outLen {
						sum += x[srcRow+p2] * blk.weight[wBase+2]
					}
				}
				next[dstRow+pos] = x[dstRow+pos] + gelu32(sum)
			}
		}
		x = next
	}

	// 4. Exact stride-2 max-pooled segment masks (`cand` & `anyt`) + global pooling `[cmax, cmean, amax]`
	var candMask [outLen]bool
	var anyMask [outLen]bool
	var candCount float32
	for pos := 0; pos < outLen; pos++ {
		s0, s1 := seg[pos*2], seg[pos*2+1]
		if s0 == 2 || s1 == 2 {
			candMask[pos] = true
			candCount++
		}
		if s0 > 0 || s1 > 0 {
			anyMask[pos] = true
		}
	}
	if candCount < 1 {
		candCount = 1
	}

	var pooled [3 * chDim]float32
	const negMask = float32(-1e4)
	for c := 0; c < chDim; c++ {
		row := c * outLen
		cmax := float32(-1e9)
		amax := float32(-1e9)
		var csum float32
		for pos := 0; pos < outLen; pos++ {
			v := x[row+pos]
			vc := v
			if !candMask[pos] {
				vc += negMask
			} else {
				csum += v
			}
			if vc > cmax {
				cmax = vc
			}

			va := v
			if !anyMask[pos] {
				va += negMask
			}
			if va > amax {
				amax = va
			}
		}
		pooled[c] = cmax
		pooled[chDim+c] = csum / candCount
		pooled[2*chDim+c] = amax
	}

	// 5. Dense head: Linear(144 -> 48) + GELU -> out(1) & type_out(6)
	var h [chDim]float32
	for oc := 0; oc < chDim; oc++ {
		sum := m.headB[oc]
		wRow := oc * (3 * chDim)
		for ic := 0; ic < 3*chDim; ic++ {
			sum += pooled[ic] * m.headW[wRow+ic]
		}
		h[oc] = gelu32(sum)
	}

	logit := float64(m.outB)
	for ic := 0; ic < chDim; ic++ {
		logit += float64(h[ic] * m.outW[ic])
	}
	prob := 1.0 / (1.0 + math.Exp(-logit))

	bestType := 0
	bestTypeLogit := float32(-1e9)
	for t := 0; t < len(secretTypes); t++ {
		tsum := m.typeOutB[t]
		wRow := t * chDim
		for ic := 0; ic < chDim; ic++ {
			tsum += h[ic] * m.typeOutW[wRow+ic]
		}
		if tsum > bestTypeLogit {
			bestTypeLogit = tsum
			bestType = t
		}
	}

	return Prediction{
		Prob:  prob,
		Kind:  secretTypes[bestType],
		Model: "builtin-tiny-cnn",
	}
}
