package main

import "time"

// Cmd is the operation a client is asking the daemon to perform.
type Cmd string

const (
	// CmdPing responds with [Ack].
	CmdPing Cmd = "ping"
	// CmdStatus responds with the current [State].
	CmdStatus Cmd = "status"
	// CmdWatch responds with the current [State] and every update until the
	// client disconnects.
	CmdWatch Cmd = "watch"
	// CmdWait blocks until any in-flight run finishes, then responds with the
	// resulting [State]. If nothing is in flight, it behaves the same as
	// [CmdStatus].
	CmdWait Cmd = "wait"
	// CmdStop asks the daemon exit and responds with [Ack].
	CmdStop Cmd = "stop"
)

// Request is sent once by the client immediately after connecting.
type Request struct {
	Cmd Cmd `json:"cmd"`
}

// Phase is where a test run currently stands.
type Phase string

const (
	PhaseRunning Phase = "running"
	PhasePassed  Phase = "passed"
	PhaseFailed  Phase = "failed"
)

// Trigger is the cause of a state change.
type Trigger string

const (
	TriggerStartup  Trigger = "startup"
	TriggerFsChange Trigger = "fs-change"
)

// State is a snapshot of the daemon's latest test run.
type State struct {
	Phase     Phase     `json:"phase"`
	Root      string    `json:"root"`
	Pkg       string    `json:"pkg"`
	Trigger   Trigger   `json:"trigger"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at,omitempty"` // zero while Phase == running
	Output    string    `json:"output,omitempty"`   // combined `go test` stdout+stderr
	RunErr    string    `json:"run_err,omitempty"`
}

// Ack is the empty response.
type Ack struct {
	OK bool `json:"ok"`
}
