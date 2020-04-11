# laia-daemon

Daemon exposing a REST API to interact with [Laia](https://github.com/jpuigcerver/Laia), running on a distant server (Raoh for our project).

# How to launch
Laia should be installed on a server with one or more good GPU(s). The daemon is currently made to use `laia-docker`,
the docker installed version of Laia. This daemon is simply a Golang executable, launched as a linux service on the server.

On Raoh (INSA's server on which we work), run the following command from the HOME of the `kub_info` account to start the daemon:
```shell script
sudo ./laia-daemon/releases/laia-daemon --data_path /tmp/kub_info/data-daemon/ --model_path /home/kub_info/laia-daemon/model.t7 --symbols_path /home/kub_info/laia-daemon/symbs.txt
```

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
		    },
		    ...
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
          },
          ...
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
        
    
