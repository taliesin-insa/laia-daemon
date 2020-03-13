package main

import (
	"encoding/json"
	"fmt"
	"github.com/gorilla/mux"
	"io/ioutil"
	"log"
	"net/http"
	"os/exec"
)

type RecoParams struct {
	Path string `json:"path"`
}

func home(w http.ResponseWriter, r *http.Request) {
	fmt.Fprint(w, "This API is a daemon enabling you to interact with Laia")
}

func recognizeImg(w http.ResponseWriter, r *http.Request) {
	// get request body
	reqBody, err := ioutil.ReadAll(r.Body)
	if err != nil {
		log.Printf("[ERROR] Request body: %v", err.Error())
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Couldn't parse body of received request"))
		return
	}

	// converts body to json
	var reqData RecoParams
	err = json.Unmarshal(reqBody, &reqData)
	if err != nil {
		log.Printf("[ERROR] Unmarshal body: %v", err.Error())
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("Couldn't unmarshal received body to JSON"))
		return
	}

	log.Printf("[INFO] Request body: %+v", reqData)

	//https://blog.kowalczyk.info/article/wOYk/advanced-command-execution-in-go-with-osexec.html

	args := []string{"-a", "-l"}

	cmd := exec.Command("ls", args...)

	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("[ERROR] 'ls' failed with %s", err)
	}

	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, reqData.Path+string(out))

}

func main() {
	router := mux.NewRouter().StrictSlash(true)
	router.HandleFunc("/", home)

	router.HandleFunc("/recognizeImg", recognizeImg).Methods("GET")

	log.Fatal(http.ListenAndServe(":8080", router))

}
