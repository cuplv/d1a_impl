//expect(buckets.arrays.swap(numberArray, 0, 6)).toEqual(false);

//beforeEach setup code

var a = [1];
var b = [8];
var c = [10];

var obj_array = [a,a,b,c];
var num_array = [1,8,8,8,10,10];

//inlined buckets.arrays.swap(num_array, 0, 6)

var array = num_array;
var i = 0;
var j = 6;

if (i < 0 || i >= array.length || j < 0 || j >= array.length )
{ return false; }

var temp = array[i];
array[i] = array[j];
array[j] = temp;
return true;
