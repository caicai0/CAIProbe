var superagent = require('superagent');
var fs = require('fs');

var allurl = 'https://mobile.cn-healthcare.com/appserver/phone/sch4_TabPage.xhtml';
var xueyuan = 'https://mobile.cn-healthcare.com/appserver/phone/sch4_CourseForClass.xhtml?classId=6&page=1&pushtime=0';
var detailUrl = 'https://mobile.cn-healthcare.com/appserver/phone/sch4_CourseDetail.xhtml?courseId=128';
var allCourse = [];
var allwrong = [];
var allWright = [];

var wrongCount = 0;
var rightCount = 0;

start();


function start() {
    getAppUrl(allurl,function (err, res) {
        if (err) {
            console.log(err);
        }else {
            var jsonModel = JSON.parse(res.text);
            var allclassIds = [];
            for (var i=0;i<jsonModel.datas.length;i++){
                var model = jsonModel.datas[i];
                if (model.type === 4) {
                    console.log(model.classId);
                    allclassIds.push(model.classId);
                }
                if (model.type === 3 || model.type === 4) {
                    for (var j = 0; j < model.courses.length; j++) {
                        allCourse.push(model.courses[j]);
                    }
                }
            }
            getall(allclassIds,0,function (err) {
                if (err) {
                    console.log(err);
                }else {
                    getallDetail(allCourse,0,function (err) {
                        if (err) {
                            console.log(err);
                        }else {
                            console.log(allwrong);
                            console.log(allwrong.length);
                            var Str = JSON.stringify(allwrong);
                            fs.writeFile('all.json',Str,function (err) {
                                console.log(err);
                            });
                            console.log("right:",rightCount);
                            console.log("wrong:",wrongCount);
                        }
                    });
                }
            })
        }
    });
}

function getallDetail(courses,index,cb) {
    if (index<courses.length){
        var course = courses[index];
        var courseId = course.courseId;
        var url = 'https://mobile.cn-healthcare.com/appserver/phone/sch4_CourseDetail.xhtml?courseId='+courseId;
        // console.log(url);
        getAppUrl(url,function (err, res) {
            if (err) {
                cb(err);
            }else {
                var jsonModel = JSON.parse(res.text);
                var finish = true;
                for (var i=0;i<jsonModel.course.catalog.length;i++){
                    var catalog = jsonModel.course.catalog[i];
                    if (catalog.videoSize<=0 || catalog.length<=0){
                        var wrong = course.courseName+'('+course.courseId+')\t'+catalog.lessonName+'('+catalog.lessonId+')';
                        allwrong.push(wrong);
                        finish = false;
                    }
                }
                if (finish){
                    var right = course.courseName+'('+course.courseId+')('+course.classId+')';
                    console.log(right);
                    allWright.push(right);
                    rightCount = rightCount+1;
                }else {
                    var right = course.courseName+'('+course.courseId+')('+course.classId+')sssss';
                    wrongCount = wrongCount+1;
                    console.log(right)
                }
                getallDetail(courses,index+1,cb);
            }
        });
    }else {
        cb();
    }
}

function getall(classIds, index, cb) {
    if (index < classIds.length) {
        var classId = classIds[index];
        getallClass(classId,1,function (err) {
            if (err) {
                cb(err);
            }else {
                getall(classIds,index+1,cb);
            }
        });
    }else {
        cb();
    }
}


function getallClass(classId, page, cb) {
    var classUrl = 'https://mobile.cn-healthcare.com/appserver/phone/sch4_CourseForClass.xhtml?classId='+classId+'&page='+page+'&pushtime=0';
    console.log(classUrl);
    getAppUrl(classUrl,function (err, res) {
        if (err) {
            cb(err);
        }else {
            var jsonModel = JSON.parse(res.text);
            if (jsonModel.datas.length){
                for (var i = 0; i < jsonModel.datas.length; i++) {
                    var model = jsonModel.datas[i];
                    model.classId = classId;
                    allCourse.push(model);
                }
                getallClass(classId,page+1,cb);
            } else {
                cb();
            }
        }
    });
}

function getAppUrl(url,cb) {
    superagent.get(url)
        .set("Host","mobile.cn-healthcare.com")
        .set("memcard","2f95e027dab448be8f1451185f0920d4")
        .set("version","12.1.2")
        .set("Accept","*/*")
        .set("channel","zgjkj_1001")
        .set("display","414.000000x736.000000")
        .set("appversion","4600")
        .set("appBundleIdentifier","com.appstore.zgjkjiphone")
        .set("Accept-Language","zh-Hans-CN;q=1")
        .set("Accept-Encoding","br, gzip, deflate")
        .set("token","Y9ZvscF__c8kMB3vh_.X5lCV4jeJFy6aJv2hXr.Top9fKpUJFfC1zhK3C3XLIZ0BkgJotNnZvQIoSSE7ondHkA==")
        .set("sid","1551403267295.531006")
        .set("id","7b67b83c960c92ad7e1b8e31e3a8522eaa45a303")
        .set("User-Agent","JianKangJie3/4.6.4 (iPhone; iOS 12.1.2; Scale/3.00)")
        .set("ssid","42eb07768c97503e6e456ee50122e4fb")
        .set("Connection","keep-alive")
        .set("model","iPhone9,2")
        .end(cb);
}