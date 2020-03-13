package main

import (
	"encoding/json"
	"fmt"
	"github.com/gorilla/mux"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
)

//////////////////// CONSTS ////////////////////

const (
	DataPath     = "data/"
	ModelPath    = "~/Documents/INSA/4INFO/Projet-4INFO/LAIA/Laia-master/egs/spanish-numbers/model.t7"
	SymbolsTable = "~/Documents/INSA/4INFO/Projet-4INFO/LAIA/Laia-master/egs/spanish-numbers/data/lang/char/symbs.txt"
	Imgs2Decode  = "data/imgs2decode.txt"
)

//////////////////// STRUCTURES ////////////////////

type RecoParams struct {
	Url string `json:"url"`
}

type LineImg struct {
	Url  string
	Name string
	Ext  string
}

//////////////////// HELPER FUNCTIONS ////////////////////

func downloadImg(img LineImg) error {
	// don't worry about errors
	response, err := http.Get(img.Url)
	if err != nil {
		log.Printf("[ERROR] downloadImg => Couldn't get image:\n%v", err.Error())
		return err
	}

	//open a file for writing
	file, err := os.Create(DataPath + img.Name + img.Ext)
	if err != nil {
		log.Printf("[ERROR] downloadImg => Couldn't create image file:\n%v", err.Error())
		return err
	}
	defer file.Close()

	// Use io.Copy to just dump the response body to the file. This supports huge files
	_, err = io.Copy(file, response.Body)
	if err != nil {
		log.Printf("[ERROR] downloadImg => Couldn't copy data to recreate image:\n%v", err.Error())
		return err
	}

	return nil
}

/**
 * NOTE: If list of images already exists, replace it.
 */
func listImgs2Decode(imgs []LineImg) error {
	f, err := os.Create(Imgs2Decode)
	if err != nil {
		log.Printf("[ERROR] listImgs2Decode => Couldn't create list file:\n%v", err.Error())
		return err
	}
	defer f.Close()

	for _, img := range imgs {
		_, err = f.WriteString(DataPath + img.Name + "." + img.Ext + "\n")
		if err != nil {
			log.Printf("[ERROR] listImgs2Decode => Error writing in file:\n%v", err.Error())
			return err
		}
	}

	return nil
}

/**
 * Transform the decode output into a real transcription
 */
func decode2Transc(decode string, img LineImg) {
	// remove name of the img
	strings.Replace(decode, img.Name, "", -1)

	// remove spaces between letters
	strings.Join(strings.Fields(decode), "")

	// transform "space" symbols into real spaces
	strings.Replace(decode, "{space}", "", -1)
}

//////////////////// LAIA TOOLKIT COMMANDS ////////////////////

func laiaDecode(img LineImg) (string, error) {

	args := []string{"decode",
		"--symbols_table", SymbolsTable,
		ModelPath,
		Imgs2Decode}

	cmd := exec.Command("laia-docker", args...)

	decode, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("[ERROR] laiaDecode failed with:\n%v caused by\n%v", err.Error(), string(decode))
		return "", err
	}

	transc := string(decode)
	decode2Transc(transc, img)

	return transc, nil
}

//////////////////// API REQUESTS ////////////////////

func home(w http.ResponseWriter, r *http.Request) {
	fmt.Fprint(w, "This daemon exposes an API enabling you to interact with Laia")
}

func recognizeImg(w http.ResponseWriter, r *http.Request) {
	// get request body
	reqBody, err := ioutil.ReadAll(r.Body)
	if err != nil {
		log.Printf("[ERROR] recognizeImg => Request body:\n%v", err.Error())
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Couldn't parse body of received request"))
		return
	}

	// convert body to json
	var reqData RecoParams
	err = json.Unmarshal(reqBody, &reqData)
	if err != nil {
		log.Printf("[ERROR] recognizeImg => Unmarshal body:\n%v", err.Error())
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("Couldn't unmarshal received body to JSON"))
		return
	}

	log.Printf("[INFO] recognizeImg => Received request body:\n%+v", reqData)

	// create LineImg from url
	segments := strings.Split(reqData.Url, "/")
	imageNameWithExt := segments[len(segments)-1] // image name + extension
	segments = strings.Split(imageNameWithExt, ".")
	img := LineImg{reqData.Url, segments[0], segments[1]}

	// download image from url
	err = downloadImg(img)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Failed downloading image at given url"))
		return
	}

	log.Printf("[INFO] recognizeImg => Image downloaded")

	// save image's local path to the list of images to decode
	err = listImgs2Decode([]LineImg{img})
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Error processing given image"))
		return
	}

	log.Printf("[INFO] recognizeImg => Image in queue to be decoded")

	transcript, err := laiaDecode(img)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Error with the recognizer when transcribing image"))
		return
	}

	log.Printf("[INFO] recognizeImg => Image decoded")

	// send successful response to user
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, transcript)

}

//////////////////// MAIN OF THE DAEMON ////////////////////

func main() {
	router := mux.NewRouter().StrictSlash(true)
	router.HandleFunc("/", home)

	router.HandleFunc("/recognizeImg", recognizeImg).Methods("GET")

	log.Fatal(http.ListenAndServe(":8080", router))

}
