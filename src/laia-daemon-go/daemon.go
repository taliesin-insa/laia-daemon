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
	DataPath    = "data/"
	Imgs2Decode = "data/imgs2decode.txt"
	SizeImg     = "64"

	/* Raoh */
	//ModelPath    = "~/Documents/INSA/4INFO/Projet-4INFO/LAIA/Laia-master/egs/spanish-numbers/model.t7"
	//SymbolsTable = "~/Documents/INSA/4INFO/Projet-4INFO/LAIA/Laia-master/egs/spanish-numbers/data/lang/char/symbs.txt"

	/* Local */
	ModelPath    = "model.t7"
	SymbolsTable = "symbs.txt"
)

//////////////////// STRUCTURES ////////////////////

type ReqBody struct {
	Images []*LineImg
}

type LineImg struct {
	Url        string
	Id         string
	transc     string
	name       string
	ext        string
	nameAndExt string
}

type ReqRes struct {
	Images []ImgValue
}

type ImgValue struct {
	Id    string
	Value string
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
	file, err := os.Create(DataPath + img.nameAndExt)
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

func resizeImg(img LineImg) error {
	args := []string{DataPath + img.nameAndExt,
		"-resize",
		"x" + SizeImg,
		DataPath + img.nameAndExt}

	cmd := exec.Command("convert", args...)

	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("[ERROR] resizeImg failed with:\n%v caused by\n%v", err.Error(), string(out))
		return err
	}

	return nil
}

/**
 * NOTE: If list of images already exists, replace it.
 */
func listImgs2Decode(imgs []*LineImg) error {
	f, err := os.Create(Imgs2Decode)
	if err != nil {
		log.Printf("[ERROR] listImgs2Decode => Couldn't create list file:\n%v", err.Error())
		return err
	}
	defer f.Close()

	for _, img := range imgs {
		_, err = f.WriteString(DataPath + img.nameAndExt + "\n")
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
func decode2Transc(laiaOutput string, imgs []*LineImg) {
	// split the output in lines, one line being the translation for one image
	lines := strings.Split(laiaOutput, "\n")

	for i := 0; i < len(lines)-1; i++ { // last line is empty
		// remove name of the img
		transc := strings.Replace(lines[i], imgs[i].name, "", -1)

		// remove spaces between letters
		transc = strings.Join(strings.Fields(transc), "")

		// transform "space" symbols into real spaces
		transc = strings.Replace(transc, "{space}", " ", -1)

		imgs[i].transc = transc
		log.Printf("[INFO] recognizeImg => Transcription for image %s: \"%s\"", imgs[i].name, imgs[i].transc)
	}
}

//////////////////// LAIA TOOLKIT COMMANDS ////////////////////

func laiaDecode(imgs []*LineImg) error {

	args := []string{"decode",
		"--symbols_table", SymbolsTable,
		ModelPath,
		Imgs2Decode}

	cmd := exec.Command("laia-docker", args...)

	laiaOutput, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("[ERROR] laiaDecode failed with:\n%v caused by\n%v", err.Error(), string(laiaOutput))
		return err
	}

	decode2Transc(string(laiaOutput), imgs)

	return nil
}

//////////////////// API REQUESTS ////////////////////

func home(w http.ResponseWriter, r *http.Request) {
	fmt.Fprint(w, "This daemon exposes an API enabling you to interact with Laia")
}

func recognizeImgs(w http.ResponseWriter, r *http.Request) {
	// get request body
	reqBody, err := ioutil.ReadAll(r.Body)
	if err != nil {
		log.Printf("[ERROR] recognizeImg => Request body:\n%v", err.Error())
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Couldn't parse body of received request"))
		return
	}

	// convert body to json
	var reqImgs ReqBody
	err = json.Unmarshal(reqBody, &reqImgs)
	if err != nil {
		log.Printf("[ERROR] recognizeImg => Unmarshal body:\n%v", err.Error())
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("Couldn't unmarshal received body to JSON"))
		return
	}

	for _, img := range reqImgs.Images {

		// create LineImg from url
		segments := strings.Split(img.Url, "/")
		imageNameWithExt := segments[len(segments)-1] // image name + extension
		segments = strings.Split(imageNameWithExt, ".")
		img.name = segments[0]
		img.ext = segments[1]
		img.nameAndExt = imageNameWithExt

		// download image from url
		err = downloadImg(*img)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte("Failed downloading image at given url"))
			return
		}
		log.Printf("[INFO] recognizeImg => Image " + img.name + " downloaded")

		// resize downloaded image
		err = resizeImg(*img)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte("Error while processing given image"))
			return
		}
		log.Printf("[INFO] recognizeImg => Image resized")
	}

	// save image's local path to the list of images to decode
	err = listImgs2Decode(reqImgs.Images)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Error processing given image"))
		return
	}
	log.Printf("[INFO] recognizeImg => Images waiting to be decoded")

	// decode image to get its transcription using laia
	err = laiaDecode(reqImgs.Images)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Error with the recognizer when transcribing image"))
		return
	}

	var reqResponse ReqRes
	for _, img := range reqImgs.Images {
		// delete image when we no longer use it, to free storage space
		err = os.Remove(DataPath + img.nameAndExt)
		if err != nil {
			log.Printf("[WARN] recognizeImg => Error deleting image %s afterward", img.nameAndExt)
		}

		// keep only useful fields for the response
		reqResponse.Images = append(reqResponse.Images, ImgValue{
			Id:    img.Id,
			Value: img.transc,
		})
	}

	// transform the response into JSON
	jsonData, err := json.Marshal(reqResponse)
	if err != nil {
		log.Printf("[ERROR] recognizeImg => Fail marshalling response to JSON:\n%v", err.Error())
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Error formatting response"))
		return
	}

	// send successful response to user
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write(jsonData)
	log.Printf("[INFO] recognizeImg => response sent")

}

//////////////////// MAIN OF THE DAEMON ////////////////////

func main() {
	log.Printf("-------------------- LAIA DAEMON STARTED --------------------")

	router := mux.NewRouter().StrictSlash(true)
	router.HandleFunc("/", home)

	router.HandleFunc("/recognizeImgs", recognizeImgs).Methods("GET")

	log.Fatal(http.ListenAndServe(":8080", router))

}
