package store

import (
	"encoding/json"
	"net/http"
)

// Dev endpoints seed the in-memory backend. They answer 404 unless the store
// is in memory mode and WAYPOINTS_ENV is dev or bench, so they never exist against a real
// database. User ids are the JWT subjects the debug client mints.
//
//	POST /dev/profile  {"user_id", "display_name", "marker_icon", "marker_trail", "paint_rgb", "car_label"}
//	POST /dev/friends  {"a", "b"}
//	POST /dev/team     {"members": [...]}
//	POST /dev/block    {"blocker", "blocked"}
func (s *Store) mountDev(mux *http.ServeMux, devEnv bool) {
	guard := func(h func(w http.ResponseWriter, r *http.Request) error) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if !devEnv || s.mem == nil {
				http.NotFound(w, r)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
			if err := h(w, r); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
			}
		}
	}
	mux.HandleFunc("POST /dev/profile", guard(func(w http.ResponseWriter, r *http.Request) error {
		var b struct {
			UserID      string `json:"user_id"`
			DisplayName string `json:"display_name"`
			MarkerIcon  string `json:"marker_icon"`
			MarkerTrail string `json:"marker_trail"`
			PaintRGB    uint32 `json:"paint_rgb"`
			CarLabel    string `json:"car_label"`
		}
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil || b.UserID == "" {
			return errBadBody
		}
		p := s.mem.setProfile(Profile{UserID: b.UserID, DisplayName: b.DisplayName, MarkerIcon: b.MarkerIcon,
			MarkerTrail: b.MarkerTrail, PaintRGB: b.PaintRGB, CarLabel: b.CarLabel})
		w.Header().Set("Content-Type", "application/json")
		return json.NewEncoder(w).Encode(map[string]any{"uid": p.UID})
	}))
	mux.HandleFunc("POST /dev/friends", guard(func(w http.ResponseWriter, r *http.Request) error {
		var b struct{ A, B string }
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil || b.A == "" || b.B == "" || b.A == b.B {
			return errBadBody
		}
		s.mem.addFriends(b.A, b.B)
		w.WriteHeader(http.StatusNoContent)
		return nil
	}))
	mux.HandleFunc("POST /dev/team", guard(func(w http.ResponseWriter, r *http.Request) error {
		var b struct{ Members []string }
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil || len(b.Members) < 2 {
			return errBadBody
		}
		s.mem.addTeam(b.Members)
		w.WriteHeader(http.StatusNoContent)
		return nil
	}))
	mux.HandleFunc("POST /dev/block", guard(func(w http.ResponseWriter, r *http.Request) error {
		var b struct{ Blocker, Blocked string }
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil || b.Blocker == "" || b.Blocked == "" {
			return errBadBody
		}
		s.mem.addBlock(b.Blocker, b.Blocked)
		w.WriteHeader(http.StatusNoContent)
		return nil
	}))
}

type devError string

func (e devError) Error() string { return string(e) }

const errBadBody = devError("bad body")
