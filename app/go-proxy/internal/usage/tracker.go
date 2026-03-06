package usage

import (
	"sort"
	"sync"
	"time"
)

const retentionDays = 120

type ModelStats struct {
	RequestCount     int `json:"request_count"`
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

type Snapshot struct {
	Daily  map[string]map[string]ModelStats `json:"daily"`
	Totals map[string]ModelStats            `json:"totals"`
}

type Tracker struct {
	mu    sync.RWMutex
	daily map[string]map[string]ModelStats
}

func NewTracker() *Tracker {
	return &Tracker{daily: make(map[string]map[string]ModelStats)}
}

func (t *Tracker) RecordRequest(model string) {
	if model == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()

	day := dayKey(time.Now())
	t.ensureDayLocked(day)
	stats := t.daily[day][model]
	stats.RequestCount++
	t.daily[day][model] = stats
	t.pruneLocked(time.Now())
}

func (t *Tracker) RecordTokens(model string, promptTokens, completionTokens int) {
	if model == "" {
		return
	}
	if promptTokens < 0 {
		promptTokens = 0
	}
	if completionTokens < 0 {
		completionTokens = 0
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	day := dayKey(time.Now())
	t.ensureDayLocked(day)
	stats := t.daily[day][model]
	stats.PromptTokens += promptTokens
	stats.CompletionTokens += completionTokens
	stats.TotalTokens += promptTokens + completionTokens
	t.daily[day][model] = stats
	t.pruneLocked(time.Now())
}

func (t *Tracker) Snapshot(days int) Snapshot {
	t.mu.RLock()
	defer t.mu.RUnlock()

	dailyOut := make(map[string]map[string]ModelStats)
	totals := make(map[string]ModelStats)

	minDay := ""
	if days > 0 {
		cutoff := time.Now().AddDate(0, 0, -(days - 1))
		minDay = dayKey(startOfDay(cutoff))
	}

	dayKeys := make([]string, 0, len(t.daily))
	for day := range t.daily {
		dayKeys = append(dayKeys, day)
	}
	sort.Strings(dayKeys)

	for _, day := range dayKeys {
		if minDay != "" && day < minDay {
			continue
		}
		models := t.daily[day]
		dailyModels := make(map[string]ModelStats, len(models))
		for model, stat := range models {
			dailyModels[model] = stat
			merged := totals[model]
			merged.RequestCount += stat.RequestCount
			merged.PromptTokens += stat.PromptTokens
			merged.CompletionTokens += stat.CompletionTokens
			merged.TotalTokens += stat.TotalTokens
			totals[model] = merged
		}
		dailyOut[day] = dailyModels
	}

	return Snapshot{
		Daily:  dailyOut,
		Totals: totals,
	}
}

func (t *Tracker) ensureDayLocked(day string) {
	if _, ok := t.daily[day]; !ok {
		t.daily[day] = make(map[string]ModelStats)
	}
}

func (t *Tracker) pruneLocked(now time.Time) {
	threshold := startOfDay(now).AddDate(0, 0, -retentionDays)
	minDay := dayKey(threshold)
	for day := range t.daily {
		if day < minDay {
			delete(t.daily, day)
		}
	}
}

func dayKey(t time.Time) string {
	return t.Format("2006-01-02")
}

func startOfDay(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, t.Location())
}
