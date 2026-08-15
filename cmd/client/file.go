package main

import (
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"os"

	"rtctl/internal/idutil"
	"rtctl/internal/proto"
)

const clientFileChunk = 256 * 1024

// cmdFilePut 上传本地文件到目标设备。
func cmdFilePut(args []string) error {
	sub := flag.NewFlagSet("file-put", flag.ExitOnError)
	token := sub.String("token", "", "目标设备 token")
	mode := sub.Uint("mode", 0o644, "文件权限（Linux 生效）")
	sub.Parse(args)
	rest := sub.Args()
	if *token == "" || len(rest) != 2 {
		fmt.Fprintln(os.Stderr, "用法: rtctl-client file-put -token <设备token> [-mode 0644] <本地文件> <远端路径>")
		os.Exit(2)
	}
	local, remote := rest[0], rest[1]
	data, err := os.ReadFile(local)
	if err != nil {
		return err
	}

	conn, err := connect()
	if err != nil {
		return err
	}
	defer conn.Close()

	id := idutil.New()
	begin, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePut, ID: id, Token: *token},
		proto.FilePutPayload{Path: remote, Mode: uint32(*mode), Size: int64(len(data))})
	if err := conn.WriteJSON(begin); err != nil {
		return err
	}
	for off := 0; off < len(data); off += clientFileChunk {
		end := off + clientFileChunk
		if end > len(data) {
			end = len(data)
		}
		chunk, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePutChunk, ID: id},
			proto.FileChunkPayload{Seq: off / clientFileChunk,
				Data: base64.StdEncoding.EncodeToString(data[off:end]), Done: end == len(data)})
		if err := conn.WriteJSON(chunk); err != nil {
			return err
		}
	}
	for {
		var m proto.Msg
		if err := conn.ReadJSON(&m); err != nil {
			return err
		}
		switch m.Type {
		case proto.TypeFilePutAck:
			var p proto.FilePutAckPayload
			m.PayloadOf(&p)
			if !p.OK {
				return errors.New(p.Error)
			}
			fmt.Printf("已上传 %s -> %s (%d 字节)\n", local, remote, len(data))
			return nil
		case proto.TypeError:
			var p proto.ErrorPayload
			m.PayloadOf(&p)
			return fmt.Errorf("[%s] %s", p.Code, p.Error)
		}
	}
}

// cmdFileGet 从目标设备下载文件到本地。
func cmdFileGet(args []string) error {
	sub := flag.NewFlagSet("file-get", flag.ExitOnError)
	token := sub.String("token", "", "目标设备 token")
	sub.Parse(args)
	rest := sub.Args()
	if *token == "" || len(rest) != 2 {
		fmt.Fprintln(os.Stderr, "用法: rtctl-client file-get -token <设备token> <远端路径> <本地文件>")
		os.Exit(2)
	}
	remote, local := rest[0], rest[1]

	conn, err := connect()
	if err != nil {
		return err
	}
	defer conn.Close()

	id := idutil.New()
	get, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFileGet, ID: id, Token: *token},
		proto.FileGetPayload{Path: remote})
	if err := conn.WriteJSON(get); err != nil {
		return err
	}
	f, err := os.Create(local)
	if err != nil {
		return err
	}
	defer f.Close()
	total := 0
	for {
		var m proto.Msg
		if err := conn.ReadJSON(&m); err != nil {
			os.Remove(local)
			return err
		}
		switch m.Type {
		case proto.TypeFileGetChunk:
			var p proto.FileGetChunkPayload
			if err := m.PayloadOf(&p); err != nil {
				os.Remove(local)
				return err
			}
			if p.Data != "" {
				b, err := base64.StdEncoding.DecodeString(p.Data)
				if err != nil {
					os.Remove(local)
					return err
				}
				if _, err := f.Write(b); err != nil {
					os.Remove(local)
					return err
				}
				total += len(b)
			}
			if p.Done {
				if p.Error != "" {
					os.Remove(local)
					return fmt.Errorf("[%s] %s", p.ErrorCode, p.Error)
				}
				fmt.Printf("已下载 %s -> %s (%d 字节)\n", remote, local, total)
				return nil
			}
		case proto.TypeError:
			var p proto.ErrorPayload
			m.PayloadOf(&p)
			os.Remove(local)
			return fmt.Errorf("[%s] %s", p.Code, p.Error)
		}
	}
}
