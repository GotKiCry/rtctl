package agent

type execProcess interface {
	Kill() error
	Close() error
}
