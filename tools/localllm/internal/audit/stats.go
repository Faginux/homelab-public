package audit

// bytesPerToken is a rough conversion for English text and logs. The report
// is an estimate, not a bill.
const bytesPerToken = 4

// StatusOK is the status of a call that gave a result.
const StatusOK = "ok"

// TaskView is the task name of a redacted view. The orchestrator reads the
// text of a view, so a view saves no tokens.
const TaskView = "view"

// Stats is the summary of a group of records.
type Stats struct {
	Calls        int            `json:"calls"`
	ByStatus     map[string]int `json:"by_status"`
	ByTask       map[string]int `json:"by_task"`
	InputBytes   int64          `json:"input_bytes"`
	OutputBytes  int64          `json:"output_bytes"`
	PromptTokens int            `json:"local_prompt_tokens"`
	OutputTokens int            `json:"local_output_tokens"`
	Redactions   int            `json:"redactions"`
	// TokensNotRead estimates the tokens that the orchestrator did not
	// read: the input of the calls that gave a result, less the result.
	TokensNotRead int64 `json:"estimated_tokens_not_read"`
}

// Summarize counts the records.
func Summarize(entries []Entry) Stats {
	stats := Stats{ByStatus: map[string]int{}, ByTask: map[string]int{}}
	for _, e := range entries {
		stats.Calls++
		stats.ByStatus[e.Status]++
		stats.ByTask[e.Task]++
		stats.PromptTokens += e.PromptTokens
		stats.OutputTokens += e.OutputTokens
		for _, n := range e.RedactionsIn {
			stats.Redactions += n
		}
		for _, n := range e.RedactionsOut {
			stats.Redactions += n
		}
		if e.Status != StatusOK || e.Task == TaskView {
			continue
		}
		stats.InputBytes += e.InputBytes
		stats.OutputBytes += e.OutputBytes
		if saved := (e.InputBytes - e.OutputBytes) / bytesPerToken; saved > 0 {
			stats.TokensNotRead += saved
		}
	}
	return stats
}
