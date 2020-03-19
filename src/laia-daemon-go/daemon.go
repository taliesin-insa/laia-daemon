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
	"strconv"
	"strings"
)

//////////////////// CONSTS ////////////////////

var (
	DataPath    = "data/"
	Imgs2Decode = DataPath + "imgs2decode.txt"
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
	// get launching args to define consts
	args := os.Args[1:]
	// check for "--help" argument
	for _, arg := range args {
		if arg == "--help" {
			if len(args) > 1 {
				fmt.Printf("Argument --help can only be used alone.\n")
				os.Exit(2)
			} else {
				fmt.Printf("Available arguments:\n" +
					"--data_path: directory where images should be downloaded and stored during execution\n" +
					"--img_height: height in pixels for images expected by the laia model\n" +
					"--model_path: location of the trained laia model\n" +
					"--symbols_path: location of the table of symbols used by the model (list of recognizable characters)\n")
				os.Exit(3)
			}
		}
	}

	// other arguments
	for i := 0; i < len(args); i += 2 {
		switch args[i] {
		case "--data_path":
			DataPath = args[i+1]
			if _, err := os.Stat(DataPath); os.IsNotExist(err) {
				fmt.Printf("Given data path (`%s`) does not exist. Please specify an existing directory.\n", DataPath)
				os.Exit(4)
			}

		case "--img_height":
			SizeImg = args[i+1]
			if _, err := strconv.Atoi(SizeImg); err != nil {
				fmt.Printf("Given image height (`%s`) isn't a number. Please use an integer.\n", SizeImg)
				os.Exit(4)
			}

		case "--model_path":
			ModelPath = args[i+1]
			if _, err := os.Stat(ModelPath); os.IsNotExist(err) {
				fmt.Printf("Given model (`%s`) does not exist. Don't forget to specify the model's filename in the path.\n", ModelPath)
				os.Exit(4)
			}

		case "--symbols_path":
			SymbolsTable = args[i+1]
			if _, err := os.Stat(SymbolsTable); os.IsNotExist(err) {
				fmt.Printf("Given symbols table (`%s`) does not exist. Don't forget to specify the symbols table's filename in the path.\n", SymbolsTable)
				os.Exit(4)
			}

		default:
			fmt.Printf("Wrong argument `%s`, try --help to get a list of all valid arguments.\n", args[i])
			os.Exit(1)
		}
	}

	// check that used commands exist
	_, err := exec.LookPath("convert")
	if err != nil {
		fmt.Printf("Missing command `convert`. This program needs ImageMagick's convert in order to process images. Please install it or verify that it's accessible in your PATH.")
		os.Exit(5)
	}

	_, err = exec.LookPath("laia-docker")
	if err != nil {
		fmt.Printf("Missing command `laia-docker`. This daemon's only purpose is to interact with the Laia HTR Toolkit. Please install it or verify that it's accessible in your PATH.")
		os.Exit(5)
	}

	// run the daemon
	log.Printf("-------------------- LAIA DAEMON STARTED --------------------")

	router := mux.NewRouter().StrictSlash(true)
	router.HandleFunc("/", home)

	router.HandleFunc("/recognizeImgs", recognizeImgs).Methods("GET")

	log.Fatal(http.ListenAndServe(":8080", router))

}
