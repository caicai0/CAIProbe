var fs = require('fs');

fs.readFile('all.json','utf8',function (err, data) {
    if (err) {
        console.log(err);
    }else {
        var array = JSON.parse(data);
        for (var i = 0; i < array.length; i++) {
            var line = array[i];
            console.log(line);
        }
        console.log(array.length);
    }
});