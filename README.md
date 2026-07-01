

# Google Drive Hosting
All images are hosted in google drive, [here](https://console.cloud.google.com/welcome?project=active-cove-373120) is a link to the Drive API project.
The service key is in `google-drive-service-key.json`(is on ezra's computer), and the access token is obtained using `get-drive-token.sh`. 
Before the access token can be obtained, two things from the service key need to be in the environment: `PRIVATE_KEY`(private_key) and `CLIENT_EMAIL`(client_email). This is done by manually adding them to the environment before running `get-drive-token.sh`. It is done this way because in production, we can't just have the service-key file in the repository, so we'll keep it locally, but manually add these two env variables so we can still creaete a token on the server side. 

`.env` file is created via the `create-env.sh` bash file.
This can only be set on Ezra's computer since it hosts the `google-drive-service-key.json`. Copy/Paste this `.env` file directly into the railway server through the railway dashboard. 


## Drive Folder 
The drive folder's ID is [`1gyKby0ifxCYvvwG-Ejw3_We6sfh1RTvp`](https://drive.google.com/drive/folders/1gyKby0ifxCYvvwG-Ejw3_We6sfh1RTvp)
This drive folder is completely public, and it must be in order for the current implementation to work. This seemed fine because it is just a folder of images that are served on the site anyway. Since this site has it's own drive service user, the entirety of that user's drive is grabbed when the server goes to download images.


### `template`
Each folder should include a template page.
Has two sections separated by `-\n`
+ Info - Describes a title and body to describe the folder
+ Order - Order in which to show the children of the folder
The children of each folder is 0-n images and 0-n folders. Child folders are also expected to have an optional `template` and 0-n children.

#### Info
This section is used to associate a title and body with a folder.  
```
title: Some Title 
body: Some body text 
```
#### Order
This section is used to specify the order in which children should be ordered.
Text can also be associated with these images by adding a hyphen after the filename.
No file extensions are used in the `order.txt` file.
```
StBenedict - Saint Benedict
Ezra - Ezra
OtherPerson - Other Person
ThisOneHasNoText
```

## TODO
- [x] Write parsers for `template` 
- [x] Pipeline improvements after the above
- [ ] finalize editorial
- [ ] finalize drive diff management (with tests!!) 
- [ ] Create drive watcher
- [ ] finalize rest of pages
