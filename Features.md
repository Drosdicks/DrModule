The module uses $Global variables so the information is available between the module amd any script that imports it.

The Customer, Asset and Ticket data are exposed via $Global:DrCustomer, $Global;DrAsset and $Global:DrTkt

The module can be used interactively. Powershell ISE will prompt for the parameters as you type... very handy for testing and new development.

Run Get-SyaVarList. It requires admin access and it will tell you if you don't have it. It reveals a list of internal system variables. they start with default values.

The system variables can be changed and new variables can be created using Set-SysVar. The parameters are:

Set-SysVar -Name 'newvar'-Value $true -Type Boolean -Add

-Type is optional. if not specified it will determine the -type from the -value 

System variables is how we tell the system how to work.

When the module is imported it runs Initialize-Environment to set the environment. It will pull the Ticket number from the asset and use it for the script. you do not need to run anything else for it to work. It will ensure all the proper folders exist. It also sets the names of the files used for Recommendations and the timer system. If there is no ticket it will create a unique folder name to use in place of the ticket number for the temp and log folders.

Initialize-Job is optional. This is the function that will create the ticket for the process. It will use the Ticket number from the Asset or create a new Ticket for the process. If a ticket is created it will rename the temp and log folders using the ticket number for the name. If you don't need a ticket you can add the -NoNewTicket switch to prevent a new ticket. You can use Initialize-Job to override the System Variables.
the following statement will turn off the file logging:

Initialize-Job-Subject "Test run." -LogToFile:$false

Complete-Job will clean-up. It will put the files from the log and temp folders that were created into a .zip file and upload the zip file to the ticket. If there is no ticket it leaves the zip file on the system. It can be deleted during regular maintenance. 

Add-LogEntry is at the heart of the system. it is the function that started everything. There are several ways to use this function. It uses the system variables as defaults to control logging.

To add an entry to logging:
Add-LogEntry "message goes here."

To accumulate entries do this...
Add-LogEntry "line 1" -Buffer @('LogEntries')
Add-LogEntry "line 2" -Buffer @('LogEntries')
Add-LogEntry "line 3" -Buffer @('LogEntries') -Flushbuffer 

The result would be one log entry with 3 lines of text.

As you may have noticed, the -Buffer parameter is an array, so you can perform the operation on several buffers with one command. When adding the buffers to the logs with -Flushbuffer it will use the BufferName as the subject for the entry on the ticket. For example,Complete-Job uses a Buffer named Completed so when it adds the last Buffer the Completed flag for the ticket is set. Future plans for Complete-Job are to auto-create the invoice. 

You can use -Buffer *All to operate on all the existing Buffers. This is useful to ensure all the buffers are logged and cleared and is used by Complete-Job. 
