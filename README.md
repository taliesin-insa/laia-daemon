# laia-daemon

Daemon exposing a REST API to interact with [Laia](https://github.com/jpuigcerver/Laia), running on a distant server (Raoh for our project).

# Usage
## How to launch
Laia should be installed on a server with one or more good GPU(s). The daemon is currently made to use `laia-docker`,
the docker installed version of Laia. This daemon is simply a Golang executable, launched as a linux service on the server.
*In fact, you can simply run this executable in a `screen` session and don't need to make it a service.*

On Raoh (INSA's server on which we work), clone this repo then run the following command from the HOME of the `kub_info` account to start the daemon:
```shell script
sudo ./laia-daemon/releases/laia-daemon --data_path /tmp/kub_info/data-daemon/ --model_path /home/kub_info/laia-daemon/data/model_SpaNum.t7 --symbols_path /home/kub_info/laia-daemon/data/symbs_SpaNum.txt
```

This command will run the daemon using the [Spanish Numbers](https://github.com/jpuigcerver/Laia/tree/master/egs/spanish-numbers) database model.

If you intend to run the daemon with the [IAM](https://github.com/jpuigcerver/Laia/tree/master/egs/iam) database model, use the following command:
```shell script
sudo ./laia-daemon/releases/laia-daemon --data_path /tmp/kub_info/data-daemon/ --model_path /home/kub_info/iam/train/lstm1d_h128.t7 --symbols_path /home/kub_info/iam/train/syms.txt --img_height 128
```

## Arguments
Available arguments:  
`--data_path`: directory where images should be downloaded and stored during execution  
`--img_height`: height in pixels for images expected by the laia model  
`--model_path`: location of the trained laia model  
`--symbols_path`: location of the table of symbols used by the model (list of recognizable characters)

## Debugging
The current version of this daemon only logs in the shell in which it is launched.
This means you have to read logs directly in the terminal.

## Using a different recognizer
In case you would like to use this executable with another recognizer than Laia, it would require to modify 
the code of the daemon and then build a new version of it.
In the next few lines, I will try to explain which functions you should modify.

Laia requires all images to have the same height. For this purpose, `resizeImg` is called after downloading them.
If you want to remove this step, just comment lines 233 to 242.

Assuming your recognizer also takes a list of all images as input, you don't need to modify `listImgs2Decode`.
If your input list has a specific format, then this is the function you need to tune a bit.

Here comes the main function that you need to change: `laiaDecode`.  
In this function, we create a shell command (line 161), then execute it and retrieve its output (variable `laiaOutput`).
This output is the standard shell output of a command-line usage of your recognizer.
Finally we transform this output to extract the transcriptions and associate them with the images.
This is done in the `decode2Transc` (called line 171).

If you understood everything above, you should already have an idea of what you will need to adapt:
1) The shell command, line 161 (replace it with your own)
2) The processing of the recognizer's output. 
If your recognizer uses a file to store the association *image / transcription*, just open and read this file in the `decode2Trans` function.

Hope this will help to understand and adapt this daemon if you need to do so!

# API

## Home Link \[/laiaDaeomon\]
Simple method to test if the Go API is running correctly.

### \[GET\]
- Response 200 (text/plain)
    ~~~
    Status: running. This daemon exposes an API enabling you to interact with Laia
    ~~~

## Retrieve transcriptions for images \[/laiaDaemon/recognizeImgs\]
Main request, used to get the transcription provided by the recognizer for given images.

### \[GET\]
- Request (application/json)
	- Body
		~~~json
	   [
		    {
		        "Url": "http://inky.local:9501/snippets/a01-007u-08.png",
		        "Id": "5e6920ebdd33ec7fd9b3ab99"
		    },
		    {
		        "Url": "http://inky.local:9501/snippets/a01-007u-09.png",
		        "Id": "42"
		    }
	   ]
		~~~
The `Id` field is the one associated with the snippet in the database of the project.
The `Url` refers to a web URL (in our case, URL of the image on the FileServer).

- Response 200 (application/json)
    - Body
        ~~~json
      [
          {
              "Id": "5e6920ebdd33ec7fd9b3ab99",
              "Value": "some random transcription"
          },
          {
              "Id": "42",
              "Value": "produced by laia"
          }
      ]
      ~~~
  The `Id` field is still the one associated with the snippet in the database of the project.
  The `Value` field is the transcription that laia gave for the image.
  
- Response 400 -> BadRequest (text/plain)
    - Body
        ~~~
        Couldn't unmarshal received body to JSON or wrong parameters
        ~~~
        The parameters of the request (JSON Body) isn't correctly formatted or fields don't match required ones.

    

- Response 500 -> InternalServerError (text/plain)
    - Body contains a description of the error. Possible errors are:
        ~~~text
        Failed downloading image {Id} at given url
        ~~~
        If one of the images is unreachable and can't be downloaded in order to decode it. Image's id in the database is also specified.  
        ~~~text
        Error while processing image {Id}
        ~~~
        If pre-processing fails for one of the images (using [ImageMagick's convert](https://imagemagick.org/index.php)). Image's id in the database is also specified.
        ~~~text
        Error preparing recognition
        ~~~
        If this error happens, it might be a problem related with the server the daemon is running on
        (missing permissions on files, ...).
        ~~~text
        Error with the recognizer when transcribing image
        ~~~
        An error occured with Laia. In that case, please refer to Laia's documentation and look for the daemon's logs.
        
    
