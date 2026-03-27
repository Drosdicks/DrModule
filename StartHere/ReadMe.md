Quick Start

Download Save-ApiKey.ps1.

Create a script in syncro and paste the code into the function.

Edit the code and modify this line accordingly: $apiKey = 'YOURAPIKEYGOESHERE'

Download the full module DrModuleV4000.psm1

Upload the module to the repository.

Create a Custom Asset Field named 'Ticket'. This is used by the module so you can run scripts over time and you don't have keep supplying a ticket number. It will use this ticket for logging until it is closed by running Complete-Job.

Add the file to the Syncro script you created for Save-Api. Dowload the file to here: C:\ProgramData\Syncro\DrOsdicks\bin\DrModule.psm1

Run the Save-ApiKey script on your test pc. 
