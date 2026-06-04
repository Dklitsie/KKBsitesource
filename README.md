

# Google Drive Hosting
All images are hosted in google drive, [here](https://console.cloud.google.com/welcome?project=active-cove-373120) is a link to the Drive API project.
The service key is in `google-drive-service-key.json`, and the access token is obtained using `get-drive-token.sh`. 
Before the access token can be obtained, two things from the service key need to be in the environment: `PRIVATE_KEY`(private_key) and `CLIENT_EMAIL`(client_email). This is done by manually adding them to the environment before running `get-drive-token.sh`. It is done this way because in production, we can't just have the service-key file in the repository, so we'll keep it locally, but manually add these two env variables so we can still creaete a token on the server side. 

Once environment variables are set:  
```bash
ACCESS_TOKEN=$(./get-drive-token.sh)
```
The drive folder's ID is [`1gyKby0ifxCYvvwG-Ejw3_We6sfh1RTvp`](https://drive.google.com/drive/folders/1gyKby0ifxCYvvwG-Ejw3_We6sfh1RTvp)
```bash
FOLDER_ID=1gyKby0ifxCYvvwG-Ejw3_We6sfh1RTvp
```
To list all files in the folder, run:
```bash
curl -s \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://www.googleapis.com/drive/v3/files?q='$FOLDER_ID'+in+parents&fields=files(id,name,mimeType)" \
  | jq
```


## Todo for mom
- Color pallette
- Prose

## Site
### Pages
- Home
- About
- Contact
- Portrait
- Editorial
- Illustration
- Post-Its
- Sketchbook



- Gallery


## Quote 
Hey Mom, 
I've outlined the quote below.

___

SCOPE OF WORK

A static, multi-page website with no database, user accounts, or admin page. The site will consist of three pages:

- Home / About — an introduction to you and your work
- Contact — includes a form that sends emails directly to you
- Portfolio — a projects page where each project includes a name, description, image label, and any number of images. Images will be hosted statically on the site at launch.

You will provide all assets, copy, and design direction. I will implement them as closely as possible to your vision while adhering to standard web design best practices.

---

PRICING

Initial build: $700 - $900

The final price within this range will depend on the complexity of the design and the number of projects included at launch. I will confirm the exact figure once we've gone through all assets and design ideas.

Post-launch changes: Because I am not building an admin page, any updates after launch will need to go through me. Small changes — such as copy updates or adding projects to the portfolio — won't cost anything extra, as long as nothing fundamental about the site needs to change.

Image storage: If the volume of project images grows to the point where static hosting is no longer practical, migrating to cloud storage (e.g. Amazon S3) is an option. This would be scoped and quoted separately if and when it becomes necessary.

---

ACCOUNTS & INFRASTRUCTURE

To host and deploy your site, you will need to create accounts with the following services:

- GitHub — used to store and manage the site's code
- Railway — used to host and serve the site

These services have free tiers that should be sufficient for a site of this scope. If usage grows beyond what the free tier covers, you would be responsible for any associated costs. Additional services may be introduced as needed and you will be notified in advance.

___


Let me know if you have any questions.

Love,
Ezra
