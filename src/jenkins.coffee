# Description:
#   Interact with your Jenkins CI server
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_JENKINS_URL
#   HUBOT_JENKINS_AUTH
#
#   Auth should be in the "user:password" format.
#
# Commands:
#   hubot jenkins b <jobNumber> - builds the job specified by jobNumber. List jobs to get number.
#   hubot jenkins build <job> - builds the specified Jenkins job
#   hubot jenkins build <job>, <params> - builds the specified Jenkins job with parameters as key=value&key2=value2
#   hubot jenkins list <filter> - lists Jenkins jobs
#   hubot jenkins describe <job> - Describes the specified Jenkins job
#   hubot jenkins last <job> - Details about the last build for the specified Jenkins job

#
# Author:
#   dougcole

querystring = require 'querystring'

# Holds a list of jobs, so we can trigger them with a number
# instead of the job's name. Gets populated on when calling
# list.
jobList = []

jenkinsBuildById = (msg) ->
  # Switch the index with the job name
  job = jobList[parseInt(msg.match[1]) - 1]

  if job
    msg.match[1] = job
    jenkinsBuild(msg)
  else
    msg.reply "I couldn't find that job. Try `jenkins list` to get a list."

fillAuth = (req) ->
    if process.env.HUBOT_JENKINS_AUTH
      auth = new Buffer(process.env.HUBOT_JENKINS_AUTH).toString('base64')
      req.headers Authorization: "Basic #{auth}"

jenkinsRequest = (msg, path, cb) ->
    req = msg.http(path)

    fillAuth(req)
    req.header('Content-Length', 0)

    if process.env.HUBOT_JENKINS_CRUMB
      getJenkinsCrumb msg, (err, crumb) ->
        if err
          cb err
        else
          req.header(crumb.crumbRequestField, crumb.crumb)
          cb null, req
    else
      cb null, req

getJenkinsCrumb = (msg, cb) ->
    url = process.env.HUBOT_JENKINS_URL
    path = "#{url}/crumbIssuer/api/json"
    req = msg.http(path)
    fillAuth(req)
    req.get() (err, res, body) ->
      if err
        cb(new Error("Failed to fetch crumb from jenkins", err))
      else
        try
          cb(null, JSON.parse(body))
        catch error
          cb(new Error("Got invalid JSON from jenkins when trying to fetch crumb", error))

jenkinsBuild = (msg, buildWithEmptyParameters) ->
    url = process.env.HUBOT_JENKINS_URL
    unescapedJob = msg.match[1]
    job = querystring.escape unescapedJob
    params = msg.match[3]
    command = if buildWithEmptyParameters then "buildWithParameters" else "build"
    path = if params then "#{url}/job/#{job}/buildWithParameters?#{params}" else "#{url}/job/#{job}/#{command}"

    jenkinsRequest msg, path, (err, req) ->
      if err
        msg.reply "Failed to create jenkins request", err
      else
        req.post() (err, res, body) ->
            if err
              msg.reply "Jenkins says: #{err}"
            else if 200 <= res.statusCode < 400 # Or, not an error code.
              msg.reply "(#{res.statusCode}) Build started for #{unescapedJob} #{url}/job/#{job}"
            else if 400 == res.statusCode
              jenkinsBuild(msg, true)
            else
              msg.reply "Jenkins says: Status #{res.statusCode} #{body}"

jenkinsDescribe = (msg) ->
    url = process.env.HUBOT_JENKINS_URL
    job = msg.match[1]

    path = "#{url}/job/#{job}/api/json"

    jenkinsRequest msg, path, (err, req) ->
      if err
        msg.reply "Failed to create jenkins request", err
      else
        req.get() (err, res, body) ->
            if err
              msg.send "Jenkins says: #{err}"
            else
              response = ""
              try
                content = JSON.parse(body)
                response += "JOB: #{content.displayName}\n"
                response += "URL: #{content.url}\n"

                if content.description
                  response += "DESCRIPTION: #{content.description}\n"

                response += "ENABLED: #{content.buildable}\n"
                response += "STATUS: #{content.color}\n"

                tmpReport = ""
                if content.healthReport.length > 0
                  for report in content.healthReport
                    tmpReport += "\n  #{report.description}"
                else
                  tmpReport = " unknown"
                response += "HEALTH: #{tmpReport}\n"

                parameters = ""
                for item in content.actions
                  if item.parameterDefinitions
                    for param in item.parameterDefinitions
                      tmpDescription = if param.description then " - #{param.description} " else ""
                      tmpDefault = if param.defaultParameterValue then " (default=#{param.defaultParameterValue.value})" else ""
                      parameters += "\n  #{param.name}#{tmpDescription}#{tmpDefault}"

                if parameters != ""
                  response += "PARAMETERS: #{parameters}\n"

                msg.send response

                if not content.lastBuild
                  return

                path = "#{url}/job/#{job}/#{content.lastBuild.number}/api/json"
                jenkinsRequest msg, path, (err, req) ->
                  if err
                    msg.reply "Failed to create jenkins request", err
                  else
                    req.get() (err, res, body) ->
                        if err
                          msg.send "Jenkins says: #{err}"
                        else
                          response = ""
                          try
                            content = JSON.parse(body)
                            console.log(JSON.stringify(content, null, 4))
                            jobstatus = content.result || 'PENDING'
                            jobdate = new Date(content.timestamp);
                            response += "LAST JOB: #{jobstatus}, #{jobdate}\n"

                            msg.send response
                          catch error
                            msg.send error

              catch error
                msg.send error

jenkinsLast = (msg) ->
    url = process.env.HUBOT_JENKINS_URL
    job = msg.match[1]

    path = "#{url}/job/#{job}/lastBuild/api/json"

    jenkinsRequest msg, path, (err, req) ->
      if err
        msg.reply "Failed to create jenkins request", err
      else
        req.get() (err, res, body) ->
            if err
              msg.send "Jenkins says: #{err}"
            else
              response = ""
              try
                content = JSON.parse(body)
                response += "NAME: #{content.fullDisplayName}\n"
                response += "URL: #{content.url}\n"

                if content.description
                  response += "DESCRIPTION: #{content.description}\n"

                response += "BUILDING: #{content.building}\n"

                msg.send response

jenkinsList = (msg) ->
    url = process.env.HUBOT_JENKINS_URL
    filter = new RegExp(msg.match[2], 'i')
    path = "#{url}/api/json"

    jenkinsRequest msg, path, (err, req) ->
      if err
        msg.reply "Failed to create jenkins request", err
      else
        req.get() (err, res, body) ->
            response = ""
            if err
              msg.send "Jenkins says: #{err}"
            else
              try
                content = JSON.parse(body)
                for jobFromServer in content.jobs
                  # Add new jobs to the jobList
                  jobList.push(jobFromServer.name) if jobList.indexOf(jobFromServer.name) is -1

                content.jobs.sort (a, b) ->
                  aIndex = jobList.indexOf a.name
                  bIndex = jobList.indexOf b.name
                  aIndex - bIndex
                .forEach (job, index) ->
                  state = if job.color == "red" then "FAIL" else "PASS"
                  if filter.test job.name
                    response += "[#{index + 1}] #{state} #{job.name}\n"
                msg.send response
              catch error
                msg.send error

module.exports = (robot) ->
  robot.respond /j(?:enkins)? build ([\w\.\-_ ]+)(, (.+))?/i, (msg) ->
    jenkinsBuild(msg, false)

  robot.respond /j(?:enkins)? b (\d+)/i, (msg) ->
    jenkinsBuildById(msg)

  robot.respond /j(?:enkins)? list( (.+))?/i, (msg) ->
    jenkinsList(msg)

  robot.respond /j(?:enkins)? describe (.*)/i, (msg) ->
    jenkinsDescribe(msg)

  robot.respond /j(?:enkins)? last (.*)/i, (msg) ->
    jenkinsLast(msg)

  robot.jenkins = {
    list: jenkinsList,
    build: jenkinsBuild
    describe: jenkinsDescribe
    last: jenkinsLast
  }
