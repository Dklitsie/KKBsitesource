

# Google Drive Hosting
All images are hosted in google drive, [here](https://console.cloud.google.com/welcome?project=active-cove-373120) is a link to the Drive API project.
The service key is in `google-drive-service-key.json`(is on ezra's computer), and the access token is obtained using `get-drive-token.sh`. 
Before the access token can be obtained, two things from the service key need to be in the environment: `PRIVATE_KEY`(private_key) and `CLIENT_EMAIL`(client_email). This is done by manually adding them to the environment before running `get-drive-token.sh`. It is done this way because in production, we can't just have the service-key file in the repository, so we'll keep it locally, but manually add these two env variables so we can still creaete a token on the server side. 

easily set these: 
```bash
export PRIVATE_KEY=$(jq -r '.private_key' google-drive-service-key.json)
export CLIENT_EMAIL=$(jq -r '.client_email' google-drive-service-key.json)
```

Once environment variables are set:  
```bash
export ACCESS_TOKEN=$(./get-drive-token.sh)
```

The drive folder's ID is [`1gyKby0ifxCYvvwG-Ejw3_We6sfh1RTvp`](https://drive.google.com/drive/folders/1gyKby0ifxCYvvwG-Ejw3_We6sfh1RTvp)
This drive folder is completely public, and it must be in order for the current implementation to work. This seemed fine because it is just a folder of images that are served on the site anyway.
```bash
export FOLDER_ID=1gyKby0ifxCYvvwG-Ejw3_We6sfh1RTvp
```

## File info conventions
### `order.txt` 
This file is used to specify the order in which images should be displayed on whichever page they are on.
Text can also be associated with these images by adding a hyphen after the filename.
No file extensions are used in the `order.txt` file.
```
StBenedict - Saint Benedict
Ezra - Ezra
OtherPerson - Other Person
ThisOneHasNoText
```
### `info.txt` 
This file is used to associate a title and body with a collection of images.  
```
title: Some Title 
body: Some body text 
```

### Editorial
Every subfolder of editorial needs to be a year.
Each editorial will show the latest first (descending order)
The `editorial` folder of google drive will have subfolders, each of which have images assoiated with a given editorial. If an image is alone, it **must** have a subfolder that it exists in. 
Each subfolder will contain an `info.txt` file that contains the title and body of the editorial.
Each subfolder contains an `order.txt` file

### Portratis
Will contain an `order.txt` file

### Picture Book
Organized the same way as the `editorial` folder, with each subfolder containing an `order.txt` file and an `info.txt` file.

### Sketches 
will contain an `order.txt` file


## TODO
- [x] Write parsers for `order.txt` and `info.txt`
- [ ] Pipeline improvements after the above
- [ ] Create drive watcher
