// Package idutil 生成消息/会话唯一ID。
package idutil

import (
	"crypto/rand"
	"encoding/hex"
)

// New 返回 32 位十六进制随机 ID。
func New() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
